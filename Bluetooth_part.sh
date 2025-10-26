#this file is for bluetooth:
# update + essentials
sudo apt update && sudo apt install -y git python3 python3-pip build-essential sdcc binutils libusb-1.0-0-dev

# optional: GNU Radio + SDR drivers (only if you plan SDR work)
sudo apt install -y gnuradio gr-osmosdr
# 1) Get official Crazyradio firmware & usb tools (Bitcraze)
git clone https://github.com/bitcraze/crazyradio-firmware.git
cd crazyradio-firmware
# build is optional if you want to compile your own; see README for CRPA flag
# to flash from the repo:
python3 ../usbtools/launchBootloader.py
sudo python3 ../usbtools/nrfbootload.py flash bin/cradio.bin
# 2) Clone BastilleResearch nRF research firmware & tools (device discovery / research)
cd ~
git clone https://github.com/BastilleResearch/nrf-research-firmware.git
cd nrf-research-firmware
# follow README to build (SDCC required)
# Example build (on Ubuntu)
make
# BastilleResearch provides research firmware and tools for Nordic nRF24LU1+ based devices; commonly used in MouseJack/Keyjack research. Use for lab discovery and to study the USB dongle firmware behavior.
# 3) Install / run nrf24-injection (educational repo — lab use)
cd ~
git clone https://github.com/xswxm/nrf24-injection.git
cd nrf24-injection
# read README — may require pip packages
sudo pip3 install -r requirements.txt
# run in listen mode for Crazyradio PA
sudo python3 app.py -l
# 4) SDR visualization (optional / advanced)
git clone https://github.com/kittennbfive/gr-nrf24-sniffer.git
# follow repo build/install instructions (may require C/C++ build steps)
# use GNU Radio Companion to open the provided flowgraph

