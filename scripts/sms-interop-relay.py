#!/usr/bin/env python3
"""
sms-interop-relay.py — Relay SMS inter-opérateur via proto-smsc-proto

Architecture :
  Chaque container opérateur exécute ce relay qui :
  1. Surveille le fichier MO SMS log (proto-smsc-daemon)
  2. Parse le TPDU SMS-SUBMIT pour extraire le numéro destinataire
  3. Détermine si le destinataire est local ou sur un autre opérateur
  4. Si distant : envoie via TCP au relay de l'opérateur cible
  5. Écoute aussi en TCP pour recevoir les MT SMS d'autres opérateurs
  6. Résout MSISDN → IMSI via le HLR local (VTY telnet)
  7. Injecte le MT SMS localement via proto-smsc-sendmt

Flux inter-opérateur :
  MS(Op1) → MSC(Op1) → HLR(Op1) → proto-smsc-daemon(Op1) → MO log
    → sms-interop-relay(Op1) [parse TPDU, route]
    → TCP → sms-interop-relay(Op2) [MSISDN→IMSI lookup, inject MT]
    → proto-smsc-sendmt(Op2) → HLR(Op2) → MSC(Op2) → MS(Op2)

Usage :
  python3 sms-interop-relay.py --config /etc/osmocom/sms-routing.conf

Env vars :
  OPERATOR_ID   : identifiant opérateur (1, 2, ...)
  CONTAINER_IP  : IP du container (172.20.0.11, .12, ...)
  HLR_VTY_PORT  : port VTY du HLR (défaut 4258)
"""

import os
import sys
import json
import time
import socket
import struct
import select
import signal
import logging
import argparse
import threading
import subprocess
from pathlib import Path
from typing import Optional, Dict, Tuple

# ═══════════════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════════════

RELAY_TCP_PORT = 7890           # Port TCP d'écoute pour les MT entrants
MO_LOG_POLL_INTERVAL = 0.5     # Intervalle polling du log MO (sec)
HLR_VTY_HOST = "127.0.0.1"
HLR_VTY_PORT = 4258
SENDMT_SOCKET = "/tmp/sendmt_socket"

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [RELAY-OP%(operator_id)s] %(levelname)s %(message)s',
    datefmt='%Y-%m-%dT%H:%M:%S'
)

# ═══════════════════════════════════════════════════════════════════════════════
# TPDU Parser — décode SMS-SUBMIT (GSM 03.40)
# ═══════════════════════════════════════════════════════════════════════════════

def decode_bcd_number(hex_bytes: bytes, num_digits: int) -> str:
    """Décode un numéro BCD swapped (format GSM standard)."""
    number = ""
    for byte in hex_bytes:
        lo = byte & 0x0F
        hi = (byte >> 4) & 0x0F
        if lo <= 9:
            number += str(lo)
        if hi <= 9 and len(number) < num_digits:
            number += str(hi)
    return number[:num_digits]


def parse_sms_submit_tpdu(hex_str: str) -> Optional[Dict]:
    """
    Parse un SMS-SUBMIT TPDU (direction MO : MS → SMSC).
    Extrait le numéro destinataire (TP-DA).
    
    Format SMS-SUBMIT (GSM 03.40 §9.2.2) :
      Octet 0     : First Octet (MTI=01 pour SUBMIT)
      Octet 1     : TP-MR (Message Reference)
      Octet 2     : TP-DA length (nombre de chiffres)
      Octet 3     : TP-DA Type of Address
      Octets 4+   : TP-DA digits (BCD swapped)
      ...suite    : TP-PID, TP-DCS, TP-VP (optionnel), TP-UDL, TP-UD
    """
    try:
        data = bytes.fromhex(hex_str.strip())
    except ValueError:
        return None
    
    if len(data) < 4:
        return None
    
    first_octet = data[0]
    mti = first_octet & 0x03
    
    # MTI=01 = SMS-SUBMIT
    if mti != 0x01:
        return None
    
    # TP-VPF (Validity Period Format) : bits 4-3
    vpf = (first_octet >> 3) & 0x03
    
    mr = data[1]          # Message Reference
    da_len = data[2]      # Nombre de chiffres dans TP-DA
    da_toa = data[3]      # Type of Address
    
    # Nombre d'octets pour les chiffres BCD : ceil(da_len / 2)
    da_bytes = (da_len + 1) // 2
    
    if len(data) < 4 + da_bytes:
        return None
    
    da_digits = decode_bcd_number(data[4:4 + da_bytes], da_len)
    
    # Type of Number (bits 6-4 du TOA)
    ton = (da_toa >> 4) & 0x07
    # Si TON=1 (international), ajouter le +
    prefix = "+" if ton == 1 else ""
    
    # Extraire aussi le corps du message si possible
    offset = 4 + da_bytes
    result = {
        "mti": "SMS-SUBMIT",
        "mr": mr,
        "da_number": f"{prefix}{da_digits}",
        "da_ton": ton,
        "da_npi": da_toa & 0x0F,
        "da_raw": da_digits,
    }
    
    # Parser TP-PID, TP-DCS, TP-VP, TP-UDL, TP-UD
    if offset < len(data):
        result["tp_pid"] = data[offset]
        offset += 1
    if offset < len(data):
        result["tp_dcs"] = data[offset]
        offset += 1
    
    # VP dépend de vpf
    if vpf == 2 and offset < len(data):  # Relative
        result["tp_vp"] = data[offset]
        offset += 1
    elif vpf == 3 and offset + 7 <= len(data):  # Absolute
        offset += 7
    elif vpf == 1 and offset + 7 <= len(data):  # Enhanced
        offset += 7
    
    if offset < len(data):
        udl = data[offset]
        result["tp_udl"] = udl
        offset += 1
        
        # Décoder le texte si DCS=0x00 (GSM 7-bit default alphabet)
        dcs = result.get("tp_dcs", 0)
        if dcs == 0x00 and offset < len(data):
            # GSM 7-bit → on laisse sms-pdu-decode s'en charger
            result["user_data_hex"] = data[offset:].hex()
    
    return result


# ═══════════════════════════════════════════════════════════════════════════════
# MO SMS Log Parser
# ═══════════════════════════════════════════════════════════════════════════════

class MOLogEntry:
    """Représente un SMS MO reçu par le proto-smsc-daemon."""
    
    def __init__(self):
        self.timestamp = ""
        self.imsi = ""
        self.sm_rp_mr = ""
        self.sm_rp_da = ""       # SMSC address
        self.sm_rp_oa = ""       # Sender MSISDN
        self.sm_rp_oa_number = ""
        self.sm_rp_ui_len = 0
        self.tpdu_hex = ""
        self.parsed_tpdu = None
    
    @property
    def destination_number(self) -> str:
        """Numéro destinataire extrait du TPDU."""
        if self.parsed_tpdu:
            return self.parsed_tpdu.get("da_raw", "")
        return ""
    
    @property
    def sender_number(self) -> str:
        """Numéro expéditeur (SM-RP-OA)."""
        return self.sm_rp_oa_number
    
    def __repr__(self):
        return (f"MOLogEntry(from={self.sender_number}, "
                f"to={self.destination_number}, imsi={self.imsi})")


def parse_mo_log_block(lines: list) -> Optional[MOLogEntry]:
    """Parse un bloc de log MO SMS (multi-lignes)."""
    entry = MOLogEntry()
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
        
        if line.endswith("Rx MO SM"):
            entry.timestamp = line.replace(" Rx MO SM", "")
        elif line.startswith("IMSI:"):
            entry.imsi = line.split(":", 1)[1].strip()
        elif line.startswith("SM-RP-MR:"):
            entry.sm_rp_mr = line.split(":", 1)[1].strip()
        elif line.startswith("SM-RP-DA:"):
            entry.sm_rp_da = line.split(":", 1)[1].strip()
        elif line.startswith("SM-RP-OA:"):
            parts = line.split()
            entry.sm_rp_oa = line.split(":", 1)[1].strip()
            # Dernier élément = numéro
            if parts:
                entry.sm_rp_oa_number = parts[-1]
        elif line.startswith("SM-RP-UI:"):
            try:
                entry.sm_rp_ui_len = int(line.split(":")[1].strip().split()[0])
            except (ValueError, IndexError):
                pass
        elif all(c in "0123456789abcdefABCDEF" for c in line) and len(line) >= 4:
            # Ligne hex = TPDU brut
            entry.tpdu_hex = line
            entry.parsed_tpdu = parse_sms_submit_tpdu(line)
    
    if entry.imsi and entry.tpdu_hex:
        return entry
    return None


# ═══════════════════════════════════════════════════════════════════════════════
# Routing Table
# ═══════════════════════════════════════════════════════════════════════════════

class RoutingTable:
    """
    Table de routage MSISDN → opérateur.
    
    Format du fichier sms-routing.conf :
      # Commentaires
      [operators]
      1 = 172.20.0.11    # Op1 container IP
      2 = 172.20.0.12    # Op2 container IP
      
      [routes]
      # prefix = operator_id
      33601 = 1           # +33601xxxxxx → Op1
      33602 = 2           # +33602xxxxxx → Op2
      1001  = 1           # Extensions courtes Op1
      2001  = 2           # Extensions courtes Op2
      
      [local]
      operator_id = 1     # ID de cet opérateur
    """
    
    def __init__(self, config_path: str):
        self.operators: Dict[str, str] = {}   # id → IP
        self.routes: list = []                 # (prefix, operator_id) trié par longueur desc
        self.local_operator_id = "1"
        self._load(config_path)
    
    def _load(self, path: str):
        section = None
        try:
            with open(path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    if line.startswith('[') and line.endswith(']'):
                        section = line[1:-1].lower()
                        continue
                    
                    if '=' not in line:
                        continue
                    key, val = line.split('=', 1)
                    key = key.strip()
                    val = val.split('#')[0].strip()  # Retirer commentaires
                    
                    if section == 'operators':
                        self.operators[key] = val
                    elif section == 'routes':
                        self.routes.append((key, val))
                    elif section == 'local':
                        if key == 'operator_id':
                            self.local_operator_id = val
            
            # Trier les routes par longueur de préfixe décroissante (longest match)
            self.routes.sort(key=lambda x: len(x[0]), reverse=True)
            
        except FileNotFoundError:
            logging.warning(f"Routing config not found: {path}, using defaults")
    
    def lookup(self, msisdn: str) -> Optional[str]:
        """Retourne l'operator_id pour un MSISDN donné, ou None."""
        # Nettoyer le numéro
        clean = msisdn.lstrip('+')
        
        for prefix, op_id in self.routes:
            if clean.startswith(prefix):
                return op_id
        return None
    
    def is_local(self, msisdn: str) -> bool:
        """Le destinataire est-il sur cet opérateur ?"""
        op = self.lookup(msisdn)
        return op == self.local_operator_id or op is None
    
    def get_operator_ip(self, op_id: str) -> Optional[str]:
        """IP du container de l'opérateur."""
        return self.operators.get(op_id)


# ═══════════════════════════════════════════════════════════════════════════════
# HLR VTY — résolution MSISDN → IMSI
# ═══════════════════════════════════════════════════════════════════════════════

def hlr_msisdn_to_imsi(msisdn: str, hlr_host: str = HLR_VTY_HOST,
                        hlr_port: int = HLR_VTY_PORT) -> Optional[str]:
    """
    Interroge le VTY d'OsmoHLR pour résoudre MSISDN → IMSI.
    Commande VTY : subscriber show msisdn <number>
    """
    clean = msisdn.lstrip('+')
    
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect((hlr_host, hlr_port))
        
        # Lire le banner
        data = b""
        while True:
            chunk = s.recv(4096)
            data += chunk
            if b"\r\n" in data and (b">" in data or b"#" in data):
                break
        
        # Envoyer la commande
        cmd = f"subscriber show msisdn {clean}\r\n"
        s.sendall(cmd.encode())
        
        # Lire la réponse
        data = b""
        deadline = time.time() + 3
        while time.time() < deadline:
            try:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
                decoded = data.decode('ascii', errors='replace')
                if decoded.count('\n') > 3 and ('>' in decoded.split('\n')[-1] 
                                                  or '#' in decoded.split('\n')[-1]):
                    break
            except socket.timeout:
                break
        
        s.close()
        
        # Parser la réponse pour trouver l'IMSI
        response = data.decode('ascii', errors='replace')
        for line in response.split('\n'):
            line = line.strip()
            if line.startswith('IMSI:'):
                imsi = line.split(':', 1)[1].strip()
                if imsi and all(c.isdigit() for c in imsi):
                    return imsi
        
        logging.warning(f"MSISDN {clean} not found in HLR")
        return None
        
    except Exception as e:
        logging.error(f"HLR VTY error: {e}")
        return None


# ═══════════════════════════════════════════════════════════════════════════════
# MT SMS Injection (local)
# ═══════════════════════════════════════════════════════════════════════════════

def inject_mt_sms(dest_imsi: str, message_text: str, from_number: str,
                   sc_address: str, sendmt_socket: str = SENDMT_SOCKET) -> bool:
    """
    Injecte un MT SMS localement via proto-smsc-sendmt.
    Pipeline : sms-encode-text | gen-sms-deliver-pdu | proto-smsc-sendmt
    """
    try:
        # Pipeline shell
        cmd = (
            f"sms-encode-text '{message_text}' "
            f"| gen-sms-deliver-pdu {from_number} "
            f"| proto-smsc-sendmt {sc_address} {dest_imsi} {sendmt_socket}"
        )
        
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=10
        )
        
        if result.returncode == 0:
            logging.info(f"MT SMS injected: IMSI={dest_imsi}")
            return True
        else:
            logging.error(f"MT SMS injection failed: {result.stderr}")
            return False
            
    except Exception as e:
        logging.error(f"MT SMS injection error: {e}")
        return False


def inject_mt_sms_raw(dest_imsi: str, tpdu_hex: str, sc_address: str,
                       sendmt_socket: str = SENDMT_SOCKET) -> bool:
    """
    Injecte un MT SMS à partir d'un TPDU brut (déjà encodé).
    On doit convertir le SMS-SUBMIT en SMS-DELIVER avant injection.
    
    Pour simplifier, on re-décode le texte et re-encode en SMS-DELIVER
    via les sms-coding-utils.
    """
    # Pour l'instant, on utilise la méthode texte via inject_mt_sms()
    # Une version future pourrait manipuler le TPDU directement
    return False


# ═══════════════════════════════════════════════════════════════════════════════
# TCP Relay Server — reçoit les MT SMS d'autres opérateurs
# ═══════════════════════════════════════════════════════════════════════════════

class RelayServer(threading.Thread):
    """
    Serveur TCP qui reçoit les requêtes MT SMS des autres opérateurs.
    
    Protocole simplifié (JSON sur TCP) :
    {
        "type": "mt_sms",
        "dest_msisdn": "33602000001",
        "from_number": "33601000001",
        "message_text": "Bonjour depuis Op1!",
        "sc_address": "19990011444",
        "sender_imsi": "001010000000001"
    }
    """
    
    def __init__(self, port: int, operator_id: str, sc_address: str):
        super().__init__(daemon=True)
        self.port = port
        self.operator_id = operator_id
        self.sc_address = sc_address
        self.running = True
    
    def run(self):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(('0.0.0.0', self.port))
        server.listen(5)
        server.settimeout(1.0)
        
        logging.info(f"Relay server listening on port {self.port}")
        
        while self.running:
            try:
                conn, addr = server.accept()
                threading.Thread(
                    target=self._handle_client,
                    args=(conn, addr),
                    daemon=True
                ).start()
            except socket.timeout:
                continue
            except Exception as e:
                logging.error(f"Server error: {e}")
        
        server.close()
    
    def _handle_client(self, conn: socket.socket, addr: tuple):
        try:
            conn.settimeout(10)
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
                # Messages JSON terminés par newline
                if b'\n' in data:
                    break
            
            if not data:
                conn.close()
                return
            
            msg = json.loads(data.decode('utf-8').strip())
            
            if msg.get("type") == "mt_sms":
                self._handle_mt_sms(msg, conn)
            else:
                response = {"status": "error", "reason": "unknown message type"}
                conn.sendall((json.dumps(response) + '\n').encode())
            
        except Exception as e:
            logging.error(f"Client handler error: {e}")
        finally:
            conn.close()
    
    def _handle_mt_sms(self, msg: dict, conn: socket.socket):
        dest_msisdn = msg.get("dest_msisdn", "")
        from_number = msg.get("from_number", "")
        message_text = msg.get("message_text", "")
        
        logging.info(f"Incoming interop MT: {from_number} → {dest_msisdn}")
        
        # Résoudre MSISDN → IMSI dans notre HLR local
        dest_imsi = hlr_msisdn_to_imsi(dest_msisdn)
        
        if not dest_imsi:
            response = {"status": "error", "reason": f"MSISDN {dest_msisdn} not found"}
            conn.sendall((json.dumps(response) + '\n').encode())
            logging.warning(f"MSISDN {dest_msisdn} not found in local HLR")
            return
        
        # Injecter le MT SMS localement
        success = inject_mt_sms(
            dest_imsi=dest_imsi,
            message_text=message_text,
            from_number=from_number,
            sc_address=self.sc_address
        )
        
        response = {
            "status": "ok" if success else "error",
            "dest_imsi": dest_imsi,
            "reason": "" if success else "injection failed"
        }
        conn.sendall((json.dumps(response) + '\n').encode())


# ═══════════════════════════════════════════════════════════════════════════════
# TCP Relay Client — envoie les MT SMS vers d'autres opérateurs
# ═══════════════════════════════════════════════════════════════════════════════

def send_interop_mt(target_ip: str, target_port: int, dest_msisdn: str,
                     from_number: str, message_text: str, sc_address: str,
                     sender_imsi: str = "") -> bool:
    """Envoie une requête MT SMS au relay d'un autre opérateur via TCP."""
    msg = {
        "type": "mt_sms",
        "dest_msisdn": dest_msisdn,
        "from_number": from_number,
        "message_text": message_text,
        "sc_address": sc_address,
        "sender_imsi": sender_imsi,
    }
    
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect((target_ip, target_port))
        s.sendall((json.dumps(msg) + '\n').encode())
        
        # Attendre la réponse
        data = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
            if b'\n' in data:
                break
        
        s.close()
        
        if data:
            response = json.loads(data.decode('utf-8').strip())
            if response.get("status") == "ok":
                logging.info(f"Interop MT delivered: {from_number} → {dest_msisdn}")
                return True
            else:
                logging.error(f"Interop MT failed: {response.get('reason')}")
                return False
        
        return False
        
    except Exception as e:
        logging.error(f"Interop send error to {target_ip}: {e}")
        return False


# ═══════════════════════════════════════════════════════════════════════════════
# GSM 7-bit Default Alphabet Decoder (basique)
# ═══════════════════════════════════════════════════════════════════════════════

GSM7_BASIC = (
    "@£$¥èéùìòÇ\nØø\rÅå"
    "Δ_ΦΓΛΩΠΨΣΘΞ\x1bÆæßÉ"
    " !\"#¤%&'()*+,-./"
    "0123456789:;<=>?"
    "¡ABCDEFGHIJKLMNO"
    "PQRSTUVWXYZÄÖÑÜ§"
    "¿abcdefghijklmno"
    "pqrstuvwxyzäöñüà"
)

def decode_gsm7(data: bytes, num_chars: int) -> str:
    """Décode du GSM 7-bit packed en texte."""
    chars = []
    bit_pos = 0
    
    for i in range(num_chars):
        byte_idx = (bit_pos * 7) // 8  # Correction: bit_pos is char index
        # Calcul correct pour GSM 7-bit unpacking
        byte_offset = (i * 7) // 8
        bit_offset = (i * 7) % 8
        
        if byte_offset >= len(data):
            break
        
        val = (data[byte_offset] >> bit_offset) & 0x7F
        if bit_offset > 1 and byte_offset + 1 < len(data):
            val = ((data[byte_offset] >> bit_offset) | 
                   (data[byte_offset + 1] << (8 - bit_offset))) & 0x7F
        
        if val < len(GSM7_BASIC):
            chars.append(GSM7_BASIC[val])
        else:
            chars.append('?')
    
    return ''.join(chars)


def extract_text_from_tpdu(tpdu_hex: str) -> str:
    """
    Tente d'extraire le texte d'un TPDU SMS-SUBMIT.
    Méthode de secours si sms-pdu-decode n'est pas disponible.
    """
    parsed = parse_sms_submit_tpdu(tpdu_hex)
    if not parsed:
        return ""
    
    dcs = parsed.get("tp_dcs", 0)
    udl = parsed.get("tp_udl", 0)
    ud_hex = parsed.get("user_data_hex", "")
    
    if dcs == 0x00 and ud_hex:
        # GSM 7-bit
        try:
            ud_bytes = bytes.fromhex(ud_hex)
            return decode_gsm7(ud_bytes, udl)
        except Exception:
            pass
    
    return ""


def extract_text_via_sms_decode(tpdu_hex: str) -> str:
    """
    Utilise sms-pdu-decode (sms-coding-utils) pour extraire le texte.
    Plus fiable que notre décodeur maison.
    """
    try:
        # Créer un fichier temporaire avec le format attendu
        # sms-pdu-decode -n attend juste le hex brut
        result = subprocess.run(
            ['sms-pdu-decode', '-n'],
            input=tpdu_hex + '\n',
            capture_output=True, text=True, timeout=5
        )
        
        if result.returncode == 0:
            # Le texte du message est après la dernière ligne vide
            lines = result.stdout.strip().split('\n')
            # Trouver la ligne "Length:" et prendre tout après
            text_lines = []
            found_length = False
            for line in lines:
                if found_length and line.strip():
                    text_lines.append(line)
                if line.strip().startswith('Length:'):
                    found_length = True
            
            if text_lines:
                return '\n'.join(text_lines).strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    
    # Fallback vers notre décodeur
    return extract_text_from_tpdu(tpdu_hex)


# ═══════════════════════════════════════════════════════════════════════════════
# MO Log Watcher — surveille le log MO et déclenche le routage
# ═══════════════════════════════════════════════════════════════════════════════

class MOLogWatcher(threading.Thread):
    """
    Surveille le fichier log MO du proto-smsc-daemon.
    Parse les nouveaux blocs et les route vers le bon opérateur.
    """
    
    def __init__(self, log_path: str, routing: RoutingTable,
                 operator_id: str, sc_address: str):
        super().__init__(daemon=True)
        self.log_path = log_path
        self.routing = routing
        self.operator_id = operator_id
        self.sc_address = sc_address
        self.running = True
        self._position = 0
    
    def run(self):
        logging.info(f"Watching MO log: {self.log_path}")
        
        # Attendre que le fichier existe
        while self.running and not Path(self.log_path).exists():
            time.sleep(2)
        
        if not self.running:
            return
        
        # Se positionner à la fin du fichier (ne pas traiter l'historique)
        with open(self.log_path, 'r') as f:
            f.seek(0, 2)  # EOF
            self._position = f.tell()
        
        logging.info(f"MO log watcher started (pos={self._position})")
        
        while self.running:
            try:
                self._check_new_entries()
            except Exception as e:
                logging.error(f"MO watcher error: {e}")
            time.sleep(MO_LOG_POLL_INTERVAL)
    
    def _check_new_entries(self):
        try:
            with open(self.log_path, 'r') as f:
                f.seek(self._position)
                new_data = f.read()
                self._position = f.tell()
        except FileNotFoundError:
            return
        
        if not new_data:
            return
        
        # Découper en blocs (séparés par des lignes contenant "Rx MO SM")
        blocks = []
        current_block = []
        
        for line in new_data.split('\n'):
            if "Rx MO SM" in line and current_block:
                blocks.append(current_block)
                current_block = [line]
            else:
                current_block.append(line)
        
        if current_block:
            blocks.append(current_block)
        
        for block in blocks:
            entry = parse_mo_log_block(block)
            if entry:
                self._route_mo_sms(entry)
    
    def _route_mo_sms(self, entry: MOLogEntry):
        dest = entry.destination_number
        sender = entry.sender_number
        
        if not dest:
            logging.warning(f"MO SMS sans destination parsable: {entry}")
            return
        
        logging.info(f"MO SMS: {sender} → {dest} (from IMSI {entry.imsi})")
        
        # Déterminer l'opérateur cible
        target_op = self.routing.lookup(dest)
        
        if target_op is None:
            logging.warning(f"No route for destination {dest}")
            return
        
        if target_op == self.operator_id:
            # Local delivery — le proto-smsc-daemon l'a déjà loggé
            # Pour un vrai SMSC, il faudrait aussi faire le MT delivery local
            logging.info(f"Local delivery for {dest} (same operator)")
            self._deliver_local(entry, dest)
            return
        
        # Inter-opérateur : envoyer au relay distant
        target_ip = self.routing.get_operator_ip(target_op)
        if not target_ip:
            logging.error(f"No IP for operator {target_op}")
            return
        
        logging.info(f"Interop route: {dest} → Op{target_op} ({target_ip})")
        
        # Extraire le texte du message
        message_text = extract_text_via_sms_decode(entry.tpdu_hex)
        if not message_text:
            message_text = extract_text_from_tpdu(entry.tpdu_hex)
        
        if not message_text:
            logging.warning(f"Could not decode message text from TPDU: {entry.tpdu_hex}")
            message_text = "[message non décodable]"
        
        # Envoyer via TCP au relay distant
        success = send_interop_mt(
            target_ip=target_ip,
            target_port=RELAY_TCP_PORT,
            dest_msisdn=dest,
            from_number=sender,
            message_text=message_text,
            sc_address=self.sc_address,
            sender_imsi=entry.imsi
        )
        
        if success:
            logging.info(f"✓ Interop SMS delivered: {sender} → {dest} (Op{target_op})")
        else:
            logging.error(f"✗ Interop SMS failed: {sender} → {dest} (Op{target_op})")
    
    def _deliver_local(self, entry: MOLogEntry, dest_msisdn: str):
        """Livraison locale — résout MSISDN→IMSI et injecte MT."""
        dest_imsi = hlr_msisdn_to_imsi(dest_msisdn)
        if not dest_imsi:
            logging.warning(f"Local MSISDN {dest_msisdn} not found in HLR")
            return
        
        message_text = extract_text_via_sms_decode(entry.tpdu_hex)
        if not message_text:
            message_text = extract_text_from_tpdu(entry.tpdu_hex)
        if not message_text:
            message_text = "[message non décodable]"
        
        inject_mt_sms(
            dest_imsi=dest_imsi,
            message_text=message_text,
            from_number=entry.sender_number,
            sc_address=self.sc_address
        )


# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description='SMS Interop Relay — routage inter-opérateur via proto-smsc-proto'
    )
    parser.add_argument(
        '--config', '-c',
        default='/etc/osmocom/sms-routing.conf',
        help='Fichier de configuration du routage SMS'
    )
    parser.add_argument(
        '--port', '-p',
        type=int, default=RELAY_TCP_PORT,
        help=f'Port TCP du relay (défaut: {RELAY_TCP_PORT})'
    )
    parser.add_argument(
        '--mo-log',
        help='Chemin du log MO (défaut: /var/log/osmocom/mo-sms-op<N>.log)'
    )
    parser.add_argument(
        '--operator-id',
        default=os.environ.get('OPERATOR_ID', '1'),
        help='ID opérateur (défaut: $OPERATOR_ID ou 1)'
    )
    
    args = parser.parse_args()
    
    op_id = args.operator_id
    sc_address = f"1999001{op_id}444"
    mo_log = args.mo_log or f"/var/log/osmocom/mo-sms-op{op_id}.log"
    
    # Injecter l'operator_id dans le format de log
    old_factory = logging.getLogRecordFactory()
    def record_factory(*a, **kw):
        record = old_factory(*a, **kw)
        record.operator_id = op_id
        return record
    logging.setLogRecordFactory(record_factory)
    
    logging.info(f"SMS Interop Relay starting")
    logging.info(f"  Operator   : {op_id}")
    logging.info(f"  SC-address : {sc_address}")
    logging.info(f"  MO log     : {mo_log}")
    logging.info(f"  TCP port   : {args.port}")
    logging.info(f"  Config     : {args.config}")
    
    # Charger la table de routage
    routing = RoutingTable(args.config)
    routing.local_operator_id = op_id
    
    logging.info(f"  Operators  : {routing.operators}")
    logging.info(f"  Routes     : {routing.routes}")
    
    # Démarrer le serveur TCP (réception MT inter-op)
    server = RelayServer(
        port=args.port,
        operator_id=op_id,
        sc_address=sc_address
    )
    server.start()
    
    # Démarrer le watcher MO log (routage MO inter-op)
    watcher = MOLogWatcher(
        log_path=mo_log,
        routing=routing,
        operator_id=op_id,
        sc_address=sc_address
    )
    watcher.start()
    
    # Boucle principale (attente signal)
    def signal_handler(sig, frame):
        logging.info("Shutting down...")
        watcher.running = False
        server.running = False
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    logging.info("Relay running. Ctrl+C to stop.")
    
    while True:
        time.sleep(1)


if __name__ == '__main__':
    main()
