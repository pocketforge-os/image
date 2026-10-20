# Boot-time defaults for the A133 codec in merged kernel-sunxi-7.x.
#
# Source facts (pocketforge-os/kernel-sunxi-7.x origin/device/a133 at
# 3010de56dbd1057513c035fff8623f80596fe9e8): the TSP device tree selects
# allwinner,speaker-amp-feed="hpout"; both speaker and headphones therefore
# share DAC Playback Volume. The codec probe pins Headphone Playback Volume to
# the reference gain 0, and its jack/DAPM policy selects Headphone versus
# Speaker. Do not override those route pins here.
#
# 38 is the nearest 0..63 hardware step to the volumeSpeaker default of 60%.
# pf-volumed reapplies the persisted value of the route read from the codec jack switch
# (headphones out = speaker, in = headphones) after this oneshot.
DAC Playback Volume=38
Headphone Playback Volume=0
