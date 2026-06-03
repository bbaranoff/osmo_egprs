# ============================================================================
# unblock.gdb — déblocage FB-det par injection du RÉSULTAT (oracle FORCE_TOA)
# Bypass du demod DSP cassé, 2 étages :
#   #1  force FBSB_CONF = success (sinon le mobile boucle sur FBSB, jamais BCCH)
#   #2  forge les DATA_IND : BCCH (rotation SI1/2/3/4) + AGCH (IMM ASSIGNMENT)
#
# Robuste : ne touche PAS last_fb (inliné/absent des symboles). Force res=0 à
# l'entrée de l1ctl_fbsb_resp (r0 = 1er arg, avant prologue).
#
# Usage (gdb attaché à qemu remote :1234, ELF layer1.highram.elf chargé) :
#   (gdb) source /opt/GSM/unblock.gdb
#   (gdb) unblock
#   (gdb) c
# ============================================================================
set $rotate = 0
set $agch_cnt = 0
set pagination off

define unblock
delete

# ---- ÉTAGE #1 : forcer le lock FB+SB --------------------------------------
# l1ctl_fbsb_resp(res) : res=0 succès, 255 échec. Le firmware appelle 255 car
# le DSP ne détecte rien. On force r0=0 À L'ENTRÉE (avant que le prologue range
# l'arg) -> tout FBSB_CONF devient un succès.
break *l1ctl_fbsb_resp
commands
silent
  set $r0 = 0
  # contenu CONF plausible (sinon snr/bsic garbage)
  set fbs.mon.snr  = 1000
  set fbs.mon.bsic = 0
  printf "[unblock #1] FBSB_CONF force SUCCESS (res=0)\n"
c
end

# ---- ÉTAGE #2 : forger le contenu L3 sur chaque DATA_IND -------------------
break l1_queue_for_l2
commands
silent
  set $hd = (struct l1ctl_hdr*)msg->l1h
  # msg_type 3 = L1CTL_DATA_IND (burst demodule qui remonte vers L2)
  if $hd->msg_type == 3
    set $dl = (struct l1ctl_info_dl*)((char*)msg->l1h + sizeof(struct l1ctl_hdr))
    set $b  = (uint8_t*)$dl + sizeof(*$dl)

    # --- BCCH (chan_nr 0x80) : rotation du type SI (octet L3 [2]) ---
    if $dl->chan_nr == 0x80
      if $rotate == 0
        set $b[2] = 0x19
      end
      if $rotate == 1
        set $b[2] = 0x1a
      end
      if $rotate == 2
        set $b[2] = 0x1b
      end
      if $rotate == 3
        set $b[2] = 0x1c
      end
      set $rotate = ($rotate + 1) % 4
      printf "[unblock #2 bcch] L3 type=%02x fn=%u\n", $b[2], $dl->frame_nr
    end

    # --- PCH/AGCH (chan_nr 0x90) : injecte IMMEDIATE ASSIGNMENT (1/10) ---
    if $dl->chan_nr == 0x90
      set $agch_cnt = $agch_cnt + 1
      if ($agch_cnt % 10) == 0
        set $b[0]  = 0x2d
        set $b[1]  = 0x06
        set $b[2]  = 0x3f
        set $b[3]  = 0x00
        set $b[4]  = 0x20
        set $b[5]  = 0x00
        set $b[6]  = 0x01
        set $b[7]  = 0x00
        set $b[8]  = 0x00
        set $b[9]  = 0x00
        set $b[10] = 0x00
        set $b[11] = 0x00
        set $b[12] = 0x2b
        set $b[13] = 0x2b
        set $b[14] = 0x2b
        set $b[15] = 0x2b
        set $b[16] = 0x2b
        set $b[17] = 0x2b
        set $b[18] = 0x2b
        set $b[19] = 0x2b
        set $b[20] = 0x2b
        set $b[21] = 0x2b
        set $b[22] = 0x2b
        printf "[unblock #2 agch %d] IMM ASS injecte fn=%u\n", $agch_cnt, $dl->frame_nr
      end
    end
  end
c
end

printf "[unblock] arme : #1 FBSB-force(res=0) + #2 BCCH/AGCH inject. Tape 'c'.\n"
end
