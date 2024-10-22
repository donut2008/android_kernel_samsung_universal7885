#! /bin/bash

set -e

codename=$(echo $1 | awk '{print tolower($0)}')
os=$(echo $2 | awk '{print tolower($0)}')

# Export build variables
export KBUILD_BUILD_USER="localhost"
export KBUILD_BUILD_HOST="localhost"
export PLATFORM_VERSION=11
export ANDROID_MAJOR_VERSION=r

SRCTREE=$(pwd)
USER=$(whoami)

# Lets make the Terminal a bit more Colorful
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Define Kernel Version
VER="v4.0-TESTBUILD"

# Compiler
TOOLCHAIN="$SRCTREE/toolchain/bin"
LLVM_DIS_ARGS="llvm-dis AR=llvm-ar AS=llvm-as NM=llvm-nm LD=ld.lld OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip"
TRIPLE="aarch64-linux-gnu-"
CROSS="$SRCTREE/toolchain/bin/aarch64-linux-gnu-"
CROSS_ARM32="$SRCTREE/toolchain/bin/arm-linux-gnueabi-"
LD="$SRCTREE/toolchain/lib"

# OS
DISTRO=$(lsb_release -d | awk -F"\t" '{print $2}')
GLIBC_VERSION=$(ldd --version | grep 'ldd (' | awk '{print $NF}')

# Simplify Pathes
PERMISSIVE="$SRCTREE/kernel_zip/aroma/kernel/permissive"
ENFORCING="$SRCTREE/kernel_zip/aroma/kernel/enforce"
ANYKERNEL="$SRCTREE/kernel_zip/anykernel"

# Telegram (Please Configure it or Type on End: No."
CHAT_ID="${KERNEL_CHAT_ID:-default_value}"
BOT_TOKEN="${KERNEL_BOT_TOKEN:-default_value}"
TELEGRAM_API="https://api.telegram.org/bot${BOT_TOKEN}"
UPLOAD_FLAG=0 # 0 if no upload, 1 if yes

# Initialize
init() {
	if ! { [ "$codename" = "a40" ] || [ "$codename" = "a30s" ] || [ "$codename" = "a30" ] || [ "$codename" = "a20e" ] || [ "$codename" = "a20" ] || [ "$codename" = "a10" ] || [ "$codename" = "jackpotlte" ]; }; then
		echo -e "${RED}Invalid device codename! Available codenames are a40, a30s, a20e, a20, a10, and jackpotlte!"
		echo -e "${RED}Exiting...${NC}\n"
		exit
	fi
	if [ -z "$CHAT_ID" ] || [ -z "$BOT_TOKEN" ]; then
		echo -e "${YELLOW}Your bot token or chat ID is empty, kernel upload will be skipped.${NC}\n"
		sleep 0.1
	else
		UPLOAD_FLAG=1
	fi
	if [ -d $SRCTREE/kernel_zip/aroma/kernel/enforce ] || [ -d $SRCTREE/kernel_zip/aroma/kernel/permissive ]; then
		sleep 0.1
	else
		mkdir $SRCTREE/kernel_zip/aroma/kernel/enforce
		mkdir $SRCTREE/kernel_zip/aroma/kernel/permissive
		sleep 0.1
	fi
	git restore $SRCTREE/kernel_zip/aroma/META-INF/com/google/android/aroma-config
	
	find "$ANYKERNEL" -type f -name "*.zip" -exec rm {} +
	echo -e "${YELLOW}Cleaning up...${NC}\n"
	rm -rf out out2 && make clean && make mrproper
	toolchain
}

glibc_patch() {
	# Patch GLIBC
	WORK_DIR=$HOME/toolchains/neutron-clang
	echo -e "${YELLOW}Downloading patchelf binary from NixOS repos...${NC}\n"
	mkdir -p "${HOME}"/.neutron-tc/patchelf-temp
	if [ -f "patchelf-0.18.0-x86_64.tar.gz" ]; then
		echo -e "${YELLOW}File exists. Skipping download.${NC}\n"
	else
		wget -qO- https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-x86_64.tar.gz | bsdtar -C "${HOME}"/.neutron-tc/patchelf-temp -xf -
	fi
	mv "${HOME}"/.neutron-tc/patchelf-temp/bin/patchelf "${HOME}"/.neutron-tc/
	rm -rf "${HOME}"/.neutron-tc/patchelf-temp
	mkdir "${HOME}"/.neutron-tc/glibc &>/dev/null || (rm -rf "${HOME}"/.neutron-tc/glibc && mkdir "${HOME}"/.neutron-tc/glibc)
	echo -e "${YELLOW}Downloading latest libs from ArchLinux repos...${NC}\n"
	wget -qO- https://archlinux.org/packages/core/x86_64/glibc/download | bsdtar -C "${HOME}"/.neutron-tc/glibc -xf -
	wget -qO- https://archlinux.org/packages/core/x86_64/lib32-glibc/download | bsdtar -C "${HOME}"/.neutron-tc/glibc -xf -
	wget -qO- https://archlinux.org/packages/core/x86_64/gcc-libs/download | bsdtar -C "${HOME}"/.neutron-tc/glibc -xf -
	wget -qO- https://archlinux.org/packages/core/x86_64/lib32-gcc-libs/download | bsdtar -C "${HOME}"/.neutron-tc/glibc -xf -
	ln -svf "${HOME}"/.neutron-tc/glibc/usr/lib "${HOME}"/.neutron-tc/glibc/usr/lib64
	echo -e "${BLUE}Patching libs...${NC}\n"
	for bin in $(find "${HOME}"/.neutron-tc/glibc -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
		bin="${bin::-1}"
		echo "Patching: ${bin}"
		"${HOME}"/.neutron-tc/patchelf --set-rpath "${HOME}"/.neutron-tc/glibc/usr/lib --force-rpath --set-interpreter "${HOME}"/.neutron-tc/glibc/usr/lib/ld-linux-x86-64.so.2 "${bin}"
	done
	echo -e "${BLUE}Patching Toolchain...${NC}\n"
	for bin in $(find "${WORK_DIR}" -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
		bin="${bin::-1}"
		echo "Patching: ${bin}"
		"${HOME}"/.neutron-tc/patchelf --add-rpath "${HOME}"/.neutron-tc/glibc/usr/lib --force-rpath --set-interpreter "${HOME}"/.neutron-tc/glibc/usr/lib/ld-linux-x86-64.so.2 "${bin}"
	done
	echo -e "${YELLOW}Cleaning...${NC}\n"
	rm -rf "${HOME}"/.neutron-tc/patchelf
	echo -e "${GREEN}Done${NC}\n"
}

# Checking toolchain
toolchain() {
	
	if [ -d "$TOOLCHAIN" ]; then
		echo -e "${GREEN}Toolchain found. Skipping download.${NC}\n"
		sleep 0.1
		select_device "$codename" "$os"
	else
		echo -e "${RED}No Toolchain found!${NC}\n"
		echo -e "${YELLOW}Warning: Toolchains need different Operating Systems!${NC}\n"
		echo -e "${RED}Warning for Neutron Toolchain! Before typing 'yes', make sure that you have 'libarchive-tools' installed, GLIBC cannot be patched!${NC}\n"
		echo -e "${YELLOW}Check below for system compatibility before continuing.${NC}\n"
		echo -e "${GREEN}Your current OS is: $DISTRO - GLIBC: $GLIBC_VERSION${NC}\n"
		if [[ "$DISTRO" == "Ubuntu 24.04 LTS" || "$DISTRO" == "Ubuntu 23.10" || "$DISTRO" == "Ubuntu 22.04.5 LTS" ]]; then
			echo -e "${YELLOW}➜ Neutron needs ${GREEN}Ubuntu 24.04 LTS | Ubuntu 23.10 | Ubuntu 22.04.5 LTS [GLIBC2.38]${NC}"
			echo -e "${YELLOW}Vortex needs ${RED}Ubuntu 21.10 [GLIBC2.34]${NC}"
			echo -e "${YELLOW}Proton needs ${RED}Ubuntu 20.04 [GLIBC2.31]${NC}"
		elif [[ "$DISTRO" == "Ubuntu 21.10" ]]; then
			echo -e "${YELLOW}Neutron needs ${RED}Ubuntu 23.10 [GLIBC2.38]${NC}"
			echo -e "${YELLOW}➜ Vortex needs ${GREEN}Ubuntu 21.10 [GLIBC2.34]${NC}"
			echo -e "${YELLOW}Proton needs ${RED}Ubuntu 20.04 [GLIBC2.31]${NC}"
		elif [[ "$DISTRO" == "Ubuntu 20.04.6 LTS" ]]; then
			echo -e "${YELLOW}Neutron needs ${RED}Ubuntu 23.10 [GLIBC2.38]${NC}"
			echo -e "${YELLOW}Vortex needs ${RED}Ubuntu 21.10 [GLIBC2.34]${NC}"
			echo -e "${YELLOW}➜ Proton needs ${GREEN}Ubuntu 20.04.6 LTS [GLIBC2.31]${NC}"
		fi
		echo ""
		echo -e "${GREEN}Download toolchain? [yes/no]${NC}\n"
		printf "${USER}:~${SRCTREE}$ "
		read -r ans
		ans=$(echo "${ans}" | tr '[:lower:]' '[:upper:]')
		while [ "$ans" != "YES" ] && [ "$ans" != "NO" ]; do
			printf "Please answer 'yes' or 'no':'\\n"
			printf "${USER}:~${SRCTREE}$ "
			read -r ans
			ans=$(echo "${ans}" | tr '[:lower:]' '[:upper:]')
		done
		if [ "$ans" = "YES" ]; then
			case "$DISTRO" in
			"Ubuntu 24.04.1 LTS" | "Ubuntu 24.04 LTS" | "Ubuntu 23.10" | "Ubuntu 23.04" | "Ubuntu 22.04.5 LTS")
				
				mkdir -p "$HOME/toolchains/neutron-clang"
				cd "$HOME/toolchains/neutron-clang" || exit
				echo -e "${RED}Downloading Neutron-Clang 18 ...${NC}\n"
				if [ -f "neutron-clang-05012024.tar.zst" ]; then
					echo -e "${YELLOW}Skipping Downloading Toolchain ... already exists!${NC}\n"
				else
					wget https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/05012024/neutron-clang-05012024.tar.zst -q --show-progress
				fi
				echo -e "${RED}Extracting tar...${NC}\n"
				tar -I zstd -xf "neutron-clang-05012024.tar.zst"
				glibc_patch
				cd "$SRCTREE" || exit
				cp -r "$HOME/toolchains/neutron-clang" toolchain
				
				select_device "$codename" "$os"
				;;
			"Ubuntu 21.10")
				echo -e "${YELLOW}Downloading Vortex-Clang Toolchain ...${NC}\n"
				git clone --depth=1 https://github.com/vijaymalav564/vortex-clang toolchain
				
				select_device "$codename" "$os"
				;;
			"Ubuntu 20.04.6 LTS")
				echo -e "${YELLOW}Downloading Proton-Clang Toolchain ...${NC}\n"
				git clone --depth=1 https://github.com/kdrag0n/proton-clang toolchain
				
				select_device "$codename" "$os"
				;;
			*)
				echo "Unsupported DISTRO: $DISTRO"
				;;
			esac
		elif [[ "$ans" == "NO" ]]; then
			
			case "$DISTRO" in
			"Ubuntu 24.04 LTS" | "Ubuntu 23.10" | "Ubuntu 23.04" | "Ubuntu 22.04.5 LTS" | "Ubuntu 21.10" | "Ubuntu 20.04.6 LTS")
				echo -e "${YELLOW}Skipping Toolchain download ...${NC}\n"
				;;
			*)
				echo "Unsupported distro: $DISTRO"
				;;
			esac
		else
			echo "Invalid answer: $ans"
		fi
	fi
}

select_device() {
	if [ "$1" = "a40" ] || [ "$1" = "a30s" ] || [ "$1" = "a30" ] || [ "$1" = "a20e" ] || [ "$1" = "a20" ] || [ "$1" = "a10" ] || [ "$1" = "jackpotlte" ]; then
		if [ "$2" = "all" ]; then
			echo -e "${BLUE}"
			build_all
			echo -e "${NC}"
		elif [ "$2" = "aosp" ]; then
			echo -e "${BLUE}"
			set_selinux_permissive
			builder_aosp
			copy_aosp
			pack_aosp
			echo -e "${NC}"
		elif [ "$2" = "oneui" ]; then
			echo -e "${BLUE}"
			set_selinux_permissive
			builder_oneui
			copy_oneui
			pack_oneui
			echo -e "${NC}"
		else
			echo -e "${RED}Exiting ...${NC}\n"
			exit
		fi
	fi
}

build_text() {
	echo -e "${RED}Debug (Permissive|Enforcing)${GREEN} ZIP created: $ZIP_FILENAME and saved in $SRCTREE/kernel_zip/${NC}\n"
	echo -e "${GREEN}***************************************************"
	echo "            Kernel: $VERSION.$PATCHLEVEL.$SUBLEVEL"
	echo "          Build Date: $(date +'%Y-%m-%d %H:%M %Z')"
	echo -e "***************************************************${NC}\n"
}

build_info() {
	if ! grep -q "# Auto-Generated by" "version"; then
		sed -i '1i# Auto-Generated by '"$0"'!' "version"
	fi
	# Auto Generate Debug/Single ZIP Build date/Version
	sed -i "s/Kernel: .*$/Kernel: $VERSION.$PATCHLEVEL.$SUBLEVEL/g" "version"
	sed -i "s/Build Date: .*/Build Date: $(date +'%Y-%m-%d %H:%M %Z')/g" "version"
}

makefile_info() {
	# Extract version information from Makefile
	VERSION=$(awk '/^VERSION/ {print $3}' Makefile)
	PATCHLEVEL=$(awk '/^PATCHLEVEL/ {print $3}' Makefile)
	SUBLEVEL=$(awk '/^SUBLEVEL/ {print $3}' Makefile)
}

set_selinux_permissive() {
	sed -i 's/# CONFIG_SECURITY_SELINUX_SETENFORCE_OVERRIDE is not set/CONFIG_SECURITY_SELINUX_SETENFORCE_OVERRIDE=y/g' arch/arm64/configs/exynos7885-${codename}_defconfig
}

set_selinux_enforcing() {
	sed -i 's/CONFIG_SECURITY_SELINUX_SETENFORCE_OVERRIDE=y/# CONFIG_SECURITY_SELINUX_SETENFORCE_OVERRIDE is not set/g' arch/arm64/configs/exynos7885-${codename}_defconfig
}

make_common() {
	trap "echo -e \"${RED}Build error!${NC}\n\"" EXIT
	PATH=$TOOLCHAIN:$PATH \
		make O=out$1 -j$(nproc --all) \
		ARCH=arm64 \
		LLVM_DIS="$LLVM_DIS_ARGS" \
		LLVM=1 \
		LLVM_IAS=1 \
		CC=clang \
		LD_LIBRARY_PATH="$LD:$LD_LIBRARY_PATH" \
		CLANG_TRIPLE=$TRIPLE \
		CROSS_COMPILE="$CROSS" \
		CROSS_COMPILE_ARM32="$CROSS_ARM32" 2>&1 | tee compile$1.log
	trap "" EXIT
}

make_out() {
	make_common
}

make_out2() {
	make_common 2
}

builder_aosp() {
	make O=out ARCH=arm64 exynos7885-${codename}_defconfig aosp.config
	
	echo -e "${GREEN}Build started for permissive AOSP kernel..."
	echo -e "${BLUE}Log location: ${SRCTREE}/compile.log${NC}\n"
	make_out

	set_selinux_enforcing
	make O=out2 ARCH=arm64 exynos7885-${codename}_defconfig aosp.config
	
	echo -e "${GREEN}Build started for enforcing AOSP kernel..."
	echo -e "${BLUE}Log location: ${SRCTREE}/compile2.log${NC}\n"
	make_out2
	echo -e "${NC}"
	echo -e "${YELLOW}Creating ZIP for $codename ...${NC}\n"
}

builder_oneui() {
	make O=out ARCH=arm64 exynos7885-${codename}_defconfig
	
	echo -e "${GREEN}Build started for permissive OneUI kernel..."
	echo -e "${BLUE}Log location: ${SRCTREE}/compile.log${NC}\n"
	make_out

	set_selinux_enforcing
	make O=out2 ARCH=arm64 exynos7885-${codename}_defconfig
	
	echo -e "${GREEN}Build started for enforcing OneUI kernel..."
	echo -e "${BLUE}Log location: ${SRCTREE}/compile2.log${NC}\n"
	make_out2
	echo -e "${NC}"
	echo -e "${YELLOW}Creating ZIP for $codename ...${NC}\n"
}

copy_oneui() {
	cp out/arch/arm64/boot/Image "$ANYKERNEL/oneui/permissive/"
	cp out2/arch/arm64/boot/Image "$ANYKERNEL/oneui/enforce/"
	if [ "$codename" = "a40" ] || [ "$codename" = "a30s" ] || [ "$codename" = "a30" ] || [ "$codename" = "a20e" ] || [ "$codename" = "a20" ] || [ "$codename" = "a10" ]; then
		cp $ANYKERNEL/prebuilt/${codename}/dtbo.img "$ANYKERNEL/oneui/enforce/"
		cp $ANYKERNEL/prebuilt/${codename}/dtbo.img "$ANYKERNEL/oneui/permissive/"
		cp $ANYKERNEL/prebuilt/${codename}/dtb.img "$ANYKERNEL/oneui/enforce/dtb.img"
		cp $ANYKERNEL/prebuilt/${codename}/dtb.img "$ANYKERNEL/oneui/permissive/dtb.img"
	elif [ "$codename" = "jackpotlte" ]; then
		cp out2/arch/arm64/boot/dtb.img "$ANYKERNEL/oneui/enforce/"
		cp out/arch/arm64/boot/dtb.img "$ANYKERNEL/oneui/permissive/"
	fi
}

copy_aosp() {
	cp out/arch/arm64/boot/Image "$ANYKERNEL/aosp/permissive/"
	cp out2/arch/arm64/boot/Image "$ANYKERNEL/aosp/enforce/"
	if [ "$codename" = "a40" ] || [ "$codename" = "a30s" ] || [ "$codename" = "a30" ] || [ "$codename" = "a20e" ] || [ "$codename" = "a20" ] || [ "$codename" = "a10" ]; then
		cp $ANYKERNEL/prebuilt/${codename}/dtbo.img "$ANYKERNEL/aosp/enforce/"
		cp $ANYKERNEL/prebuilt/${codename}/dtbo.img "$ANYKERNEL/aosp/permissive/"
		cp $ANYKERNEL/prebuilt/${codename}/dtb.img "$ANYKERNEL/aosp/enforce/dtb.img"
		cp $ANYKERNEL/prebuilt/${codename}/dtb.img "$ANYKERNEL/aosp/permissive/dtb.img"
	elif [ "$codename" = "jackpotlte" ]; then
		cp out2/arch/arm64/boot/dtb.img "$ANYKERNEL/aosp/enforce/"
		cp out/arch/arm64/boot/dtb.img "$ANYKERNEL/aosp/permissive/"
	fi
}

build_all() {
	if [[ "$codename" == "a40" || "$codename" == "a30s" || "$codename" == "a30" || "$codename" == "a20e" || "$codename" == "a20" || "$codename" == "a30" ]]; then
		set_selinux_permissive
		builder_oneui
		copy_oneui
		create_zip_permissive_oneui META-INF tools anykernel.sh Image dtb.img dtbo.img version
		create_zip_enforcing_oneui META-INF tools anykernel.sh Image dtb.img dtbo.img version
		cd "$SRCTREE" || exit
		set_selinux_permissive
		builder_aosp
		copy_aosp
		create_zip_permissive_aosp META-INF tools anykernel.sh Image dtb.img dtbo.img version
		create_zip_enforcing_aosp META-INF tools anykernel.sh Image dtb.img dtbo.img version
		aroma
	elif [ "$codename" = "jackpotlte" ]; then
		set_selinux_permissive
		builder_oneui
		copy_oneui
		create_zip_permissive_oneui META-INF tools anykernel.sh Image dtb.img version
		create_zip_enforcing_oneui META-INF tools anykernel.sh Image dtb.img version
		cd "$SRCTREE" || exit
		set_selinux_permissive
		builder_aosp
		copy_aosp
		create_zip_permissive_aosp META-INF tools anykernel.sh Image dtb.img version
		create_zip_enforcing_aosp META-INF tools anykernel.sh Image dtb.img version
		aroma
	fi
}

create_zip_permissive_aosp() {
	cd "$SRCTREE" || exit
	makefile_info
	cd "$ANYKERNEL/aosp/permissive" || exit
	build_info
	PERMISSIVE_ZIP_FILENAME="Nameless_${codename}_${VER}-debug-permissive-aosp.zip"
	zip -r9 "$PERMISSIVE_ZIP_FILENAME" "$@"
}

create_zip_enforcing_aosp() {
	cd "$SRCTREE" || exit
	makefile_info
	cd "$ANYKERNEL/aosp/enforce" || exit
	build_info
	ENFORCING_ZIP_FILENAME="Nameless_${codename}_${VER}-debug-enforcing-aosp.zip"
	zip -r9 "$ENFORCING_ZIP_FILENAME" "$@"
}

create_zip_permissive_oneui() {
	cd "$SRCTREE" || exit
	makefile_info
	cd "$ANYKERNEL/oneui/permissive" || exit
	build_info
	PERMISSIVE_ZIP_FILENAME="Nameless_${codename}_${VER}-debug-permissive-oneui.zip"
	zip -r9 "$PERMISSIVE_ZIP_FILENAME" "$@"
}

create_zip_enforcing_oneui() {
	cd "$SRCTREE" || exit
	makefile_info
	cd "$ANYKERNEL/oneui/enforce" || exit
	build_info
	ENFORCING_ZIP_FILENAME="Nameless_${codename}_${VER}-debug-enforcing-oneui.zip"
	zip -r9 "$ENFORCING_ZIP_FILENAME" "$@"
}

create_aroma() {
	cd "$SRCTREE/kernel_zip/aroma" || exit
	cp "$ANYKERNEL/oneui/permissive/Nameless_${codename}_${VER}-debug-permissive-oneui.zip" "$PERMISSIVE/oneui.zip"
	cp "$ANYKERNEL/oneui/enforce/Nameless_${codename}_${VER}-debug-enforcing-oneui.zip" "$ENFORCING/oneui.zip"
	cp "$ANYKERNEL/aosp/permissive/Nameless_${codename}_${VER}-debug-permissive-aosp.zip" "$PERMISSIVE/aosp.zip"
	cp "$ANYKERNEL/aosp/enforce/Nameless_${codename}_${VER}-debug-enforcing-aosp.zip" "$ENFORCING/aosp.zip"
	AROMA_FILENAME="Nameless_${codename}_${VER}-AROMA.zip"
	zip -r9 "$AROMA_FILENAME" "$@"
}

aroma() {
	# create and pack AROMA
	cd "$ANYKERNEL" || exit
	if [[ "$codename" == "a40" || "$codename" == "a30s" || "$codename" == "a30" || "$codename" == "a20e" || "$codename" == "a20" || "$codename" == "a10" ]]; then
	sed -i "s/sysprop/${codename}/g" "$SRCTREE/kernel_zip/aroma/META-INF/com/google/android/aroma-config"
		create_aroma META-INF tools kernel
	elif [ "$codename" = "jackpotlte" ]; then
	sed -i 's/sysprop/A8 2018/g' "$SRCTREE/kernel_zip/aroma/META-INF/com/google/android/aroma-config"
		create_aroma META-INF tools kernel
	fi
	cp "$SRCTREE/kernel_zip/aroma/$AROMA_FILENAME" "$SRCTREE/kernel_zip/"
	cd "$SRCTREE" || exit
	
	echo -e "${GREEN}AROMA Installer created: $AROMA_FILENAME and saved in $SRCTREE/kernel_zip/${NC}\n"
	build_text
	tg_upload
}

pack_aosp() {
	# create and pack ZIP
	cd "$ANYKERNEL" || exit
	if [[ "$codename" == "a40" || "$codename" == "a30s" || "$codename" == "a30" || "$codename" == "a20e" || "$codename" == "a20" || "$codename" == "a10" ]]; then
		create_zip_enforcing_aosp META-INF tools anykernel.sh Image dtb.img dtbo.img version
		create_zip_permissive_aosp META-INF tools anykernel.sh Image dtb.img dtbo.img version
	elif [ "$codename" = "jackpotlte" ]; then
		create_zip_enforcing_aosp META-INF tools anykernel.sh Image dtb.img version
		create_zip_permissive_aosp META-INF tools anykernel.sh Image dtb.img version
	fi
	while [ ! -f "$ANYKERNEL/aosp/permissive/Nameless_${codename}_${VER}-debug-permissive-aosp.zip" ] || [ ! -f "$ANYKERNEL/aosp/enforce/Nameless_${codename}_${VER}-debug-enforcing-aosp.zip" ]; do
		sleep 0.1
	done
	find "$ANYKERNEL/aosp" -type f -name "*.zip" -exec cp -t "$SRCTREE/kernel_zip" {} +
	cd "$SRCTREE" || exit
	
	build_text
	tg_upload
}

pack_oneui() {
	# create and pack ZIP
	cd "$ANYKERNEL" || exit
	if [[ "$codename" == "a40" || "$codename" == "a30s" || "$codename" == "a30" || "$codename" == "a20e" || "$codename" == "a20" || "$codename" == "a10" ]]; then
		create_zip_enforcing_oneui META-INF tools anykernel.sh Image dtb.img dtbo.img version
		create_zip_permissive_oneui META-INF tools anykernel.sh Image dtb.img dtbo.img version
	elif [ "$codename" = "jackpotlte" ]; then
		create_zip_enforcing_oneui META-INF tools anykernel.sh Image dtb.img version
		create_zip_permissive_oneui META-INF tools anykernel.sh Image dtb.img version
	fi
	while [ ! -f "$ANYKERNEL/oneui/permissive/Nameless_${codename}_${VER}-debug-permissive-oneui.zip" ] || [ ! -f "$ANYKERNEL/oneui/enforce/Nameless_${codename}_${VER}-debug-enforcing-oneui.zip" ]; do
		sleep 0.1
	done
	find "$ANYKERNEL/oneui" -type f -name "*.zip" -exec cp -t "$SRCTREE/kernel_zip" {} +
	cd "$SRCTREE" || exit
	
	build_text
	tg_upload
}

tg_upload() {
	if [ $UPLOAD_FLAG -eq 1 ]; then
		echo -e "${GREEN}Uploading $SRCTREE/kernel_zip/$PERMISSIVE_ZIP_FILENAME and $SRCTREE/kernel_zip/$ENFORCING_ZIP_FILENAME to Telegram ...${NC}"
		file_size_mb=$(stat -c "%s" "$SRCTREE/kernel_zip/${ZIP_FILENAME}" | awk '{printf "%.2f", $1 / (1024 * 1024)}')
		curl -s -F chat_id="${CHAT_ID}" -F document=@"$SRCTREE/kernel_zip/${ENFORCING_ZIP_FILENAME}" "${TELEGRAM_API}/sendDocument"
		curl -s -F chat_id="${CHAT_ID}" -F document=@"$SRCTREE/kernel_zip/${PERMISSIVE_ZIP_FILENAME}" "${TELEGRAM_API}/sendDocument"
	else
		echo -e "${RED}Telegram Upload skipped. Exiting ...${NC}\n"
		echo -e "${GREEN}ZIP Output: $SRCTREE/kernel_zip/${ZIP_FILENAME}${NC}\n"
		exit
	fi
}
init
