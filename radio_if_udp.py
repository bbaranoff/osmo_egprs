#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# radio_if_udp.py — backend radio UDP pour le transceiver gr-gsm (grgsm_trx).
#
# Remplace UHD/LMS (hardware SDR) par un transport UDP d'I/Q : relie le
# transceiver gr-gsm du MOBILE à l'I/Q continu du BTS (osmo-trx via
# calypso-ipc-device, relayé en UDP). Tout le protocole TRX (ctrl/clk/data
# vers trxcon) et la chaîne gr-gsm (gsm.receiver RX + modulateur TX) restent
# ceux du module gnuradio.gsm.trx — on ne swappe QUE la source/sink physique.
#
# Architecture (full-grgsm, IPC seulement pour le BTS) :
#   BTS:    osmo-bts → osmo-trx-ipc(SPS=4) → calypso-ipc-device ──I/Q fc32──┐
#   Mobile: mobile → trxcon → grgsm_trx[radio_if_udp] ←── udp_source ───────┘
#                                            └── udp_sink ──I/Q UL──→ device → osmo-trx
#
# Plus de DSP Calypso émulé côté mobile → plus de charge c54x → plus de
# congestion timing (cas "no-dsp", léger, qu'on sait tenir en temps réel).
#
# Ports I/Q (UDP, fc32 complexe @ sample_rate=4*270833) :
#   RX (DL du BTS)  : bind CALYPSO_TRX_IQ_RX_PORT (défaut 5810)
#   TX (UL mobile)  : send CALYPSO_TRX_IQ_TX_PORT (défaut 5811) @ udp_host
#
# Install : copier dans le module installé, à côté de radio_if_uhd.py :
#   .../site-packages/gnuradio/gsm/trx/radio_if_udp.py
# puis patcher grgsm_trx pour --driver udp (voir run.sh mode full-grgsm).

import os

from gnuradio import blocks
from gnuradio import gr

from .radio_if import RadioInterface


class RadioInterfaceUDP(RadioInterface):
    # Description humaine
    def __str__(self):
        return "UDP"

    @property
    def phy_proc_delay(self):
        # Pas de hardware → délai de traitement nominal (comme UHD, sans le
        # délai device). À affiner si trxcon se plaint du timing.
        return (285.616 + 2 * self.GSM_SYM_PERIOD_uS) * 1e-6

    def _udp(self, env, default):
        v = os.environ.get(env)
        return int(v) if (v and v.isdigit()) else default

    def phy_init_source(self):
        # I/Q DL du BTS (fc32 complexe @ sample_rate). Le device relaye l'I/Q
        # continu d'osmo-trx ici. eof=False, mtu 1472 (≈183 samples fc32/dgram).
        host = os.environ.get("CALYPSO_TRX_IQ_HOST", "127.0.0.1")
        port = self._udp("CALYPSO_TRX_IQ_RX_PORT", 5810)
        self._phy_src = blocks.udp_source(gr.sizeof_gr_complex, host, port,
                                          1472, False)

    def phy_init_sink(self):
        # I/Q UL du mobile → device → osmo-trx.
        host = os.environ.get("CALYPSO_TRX_IQ_HOST", "127.0.0.1")
        port = self._udp("CALYPSO_TRX_IQ_TX_PORT", 5811)
        self._phy_sink = blocks.udp_sink(gr.sizeof_gr_complex, host, port,
                                         1472, False)

    # Pas de hardware : les contrôles freq/gain sont des no-op (le BTS fixe
    # la fréquence ; ici on est en bande de base, l'I/Q est déjà à la bonne fc).
    def phy_set_rx_freq(self, freq):
        pass

    def phy_set_tx_freq(self, freq):
        pass

    def phy_set_rx_gain(self, gain):
        pass

    def phy_set_tx_gain(self, gain):
        pass
