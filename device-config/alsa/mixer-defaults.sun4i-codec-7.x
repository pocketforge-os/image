# Boot-time defaults for the A133 codec in merged kernel-sunxi-7.x.
#
# Source facts (pocketforge-os/kernel-sunxi-7.x origin/device/a133 at
# 3010de56dbd1057513c035fff8623f80596fe9e8): the TSP device tree selects
# allwinner,speaker-amp-feed="hpout"; both speaker and headphones therefore
# share DAC Playback Volume. Headphone Playback Volume is an inverted attenuation
# control (7 = 0 dB loudest, 0 = -42 dB); the image pins it to 7, and the jack/DAPM policy selects Headphone versus
# Speaker. Do not override those route pins here.
#
# 38 is the nearest 0..63 hardware step to the volumeSpeaker default of 60%.
# pf-volumed reapplies the persisted value of the route read from the codec jack switch
# (headphones out = speaker, in = headphones) after this oneshot.
DAC Playback Volume=38
Headphone Playback Volume=7
#
# Mic1 Boost Volume (IO8 U11, tsp-mc9m.60.29.65.26): A133 capture-path mic
# preamp boost, range 0..31 (sun4i-codec.c:2266 at the platform.lock pin 011fd206). Reset 0 fails the 1 kHz mic
# tone check (tone under the noise floor); 8..31 all pass and 16 gives the
# best 1 kHz SNR.
Mic1 Boost Volume=16
