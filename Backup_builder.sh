#!/bin/bash
set -eo pipefail
trap 'echo -e "\033[0;31mError at line $LINENO\033[0m"; exit 1' ERR

# Configuration
CONFIG_SAVE_FILE="saved_options_defconfig"
TOGGLE_FILE="use_extra_configs.toggle"
CLANG_DIR="${PWD}/toolchain/neutron_18"
BUILD_OUT_DIR="${PWD}/build/out"
FREQ_DIR="${PWD}/Freq"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Device models
declare -A BOARD_MAP=(
    [x1slte]="SRPSJ28B018KU" [x1s]="SRPSI19A018KU"
    [y2slte]="SRPSJ28A018KU" [y2s]="SRPSG12A018KU"
    [z3s]="SRPSI19B018KU" [c1slte]="SRPTC30B009KU"
    [c1s]="SRPTB27D009KU" [c2slte]="SRPTC30A009KU"
    [c2s]="SRPTB27C009KU" [r8s]="SRPTF26B014KU"
)

show_help() {
    cat << EOF
${CYAN}Usage:${NC} $(basename "$0") [options]
${YELLOW}Options:${NC}
  -m, --model MODEL    Specify device model (required)
  -k, --ksu [y/N]     Include KernelSU
  -r, --recovery [y/N] Build for Android Recovery
  -c, --ccache [y/N]  Use ccache
  -f, --freq PRESET    CPU frequency (underclocked/overclocked/original)
  -e, --extra         Enable extra configuration selection
  --toggle            Toggle saved extra configurations
  -h, --help          Show this help message
EOF
    exit 0
}

print_header() {
    echo -e "${CYAN}"
    echo "-----------------------------------------------"
    echo " $1 "
    echo "-----------------------------------------------"
    echo -e "${NC}"
}

print_error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

setup_toolchain() {
    print_header "Toolchain Setup"
    
    if [ ! -f "${CLANG_DIR}/bin/clang-18" ]; then
        echo -e "${YELLOW}Downloading Neutron toolchain...${NC}"
        mkdir -p "${CLANG_DIR}"
        
        for attempt in {1..3}; do
            curl -sL "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman" | \
            bash -s -- -S=05012024 && break
            echo -e "${YELLOW}Download failed, retrying (${attempt}/3)...${NC}"
            sleep 2
        done

        echo -e "${YELLOW}Applying patches...${NC}"
        curl -sL "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman" | \
            bash -s -- --patch=glibc --patch=binutils
    fi
    
    if [ ! -f "${CLANG_DIR}/bin/llvm-readelf" ]; then
        echo -e "${RED}Error: llvm-readelf missing from toolchain!${NC}"
        echo -e "${YELLOW}Creating symbolic link...${NC}"
        ln -s "${CLANG_DIR}/bin/llvm-readelf-18" "${CLANG_DIR}/bin/llvm-readelf"
    fi
    
    export PATH="${CLANG_DIR}/bin:${PATH}"
    export READELF="${CLANG_DIR}/bin/llvm-readelf"
}

select_extra_configs() {
    print_header "Extra Config Selection"
    
    local config_files=()
    mapfile -t config_files < <(find "Extra" -name '*.config' 2>/dev/null)
    
    [ ${#config_files[@]} -eq 0 ] && print_error "No extra configs found in Extra/ directory"

    PS3=$'\n'"Enter selection (multiple space-separated, A=All, D=Done): "
    select config in "${config_files[@]}" "Done"; do
        case $config in
            "Done") break ;;
            *) SELECTED_CONFIGS+=("$config") ;;
        esac
    done

    printf "%s\n" "${SELECTED_CONFIGS[@]}" > "${CONFIG_SAVE_FILE}"
    echo -e "${GREEN}Saved ${#SELECTED_CONFIGS[@]} configurations${NC}"
}

handle_frequency() {
    [ -z "$FREQ_OPTION" ] && return
    
    print_header "CPU Frequency Configuration"
    
    local src_file="${FREQ_DIR}/${FREQ_OPTION}.c"
    local dest_file="drivers/cpufreq/exynos-acme.c"
    
    [ ! -d "$FREQ_DIR" ] && print_error "Frequency directory not found: ${FREQ_DIR}"
    [ ! -f "$src_file" ] && print_error "Frequency preset missing: ${src_file}"
    
    if ! cp -v "$src_file" "$dest_file"; then
        print_error "Failed to copy frequency preset!"
    fi
    
    echo -e "${GREEN}Applied ${FREQ_OPTION} preset to exynos-acme.c${NC}"
}

configure_ccache() {
    [ "${CCACHE_OPTION,,}" != "y" ] && return

    print_header "CCache Configuration"
    
    if ! command -v ccache >/dev/null; then
        print_error "ccache is required but not installed!"
    fi

    export CCACHE_DIR="${PWD}/.ccache"
    export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
    export CCACHE_MAXSIZE="5G"
    
    mkdir -p "${CCACHE_DIR}"
    echo -e "${YELLOW}Cache directory: ${CCACHE_DIR}${NC}"
    echo -e "${YELLOW}Initial cache stats:${NC}"
    ccache --show-stats
    
    export CC="ccache clang"
    export CXX="ccache clang++"
}

build_kernel() {
    print_header "Kernel Compilation"
    
    local make_args=(
        LLVM=1
        LLVM_IAS=1
        ARCH=arm64
        O=out
        READELF="${CLANG_DIR}/bin/llvm-readelf"
        -j$(nproc)
    )
    
    # Apply configurations
    make "${make_args[@]}" "eyeless_${MODEL}_defconfig" eyeless.config \
        ${RECOVERY:+recovery.config} ${KSU:+ksu.config} "${SELECTED_CONFIGS[@]}"
    
    # Start build
    echo -e "${CYAN}Starting compilation...${NC}"
    time make "${make_args[@]}" 2>&1 | tee build.log
    
    # Show final ccache stats
    if [ "${CCACHE_OPTION,,}" = "y" ]; then
        echo -e "${YELLOW}Final cache stats:${NC}"
        ccache --show-stats
    fi
}

package_bootimg() {
    print_header "Creating Package"
    
    local output_dir="${BUILD_OUT_DIR}/${MODEL}"
    local version=$(grep -o 'CONFIG_LOCALVERSION="[^"]*"' arch/arm64/configs/eyeless.config | cut -d '"' -f 2)
    version=${version:1}
    local current_date=$(date +"%d-%m-%Y_%H-%M-%S")
    
    # Clean and create directories
    rm -rf "${output_dir}"
    mkdir -p "${output_dir}/zip/files" "${output_dir}/zip/META-INF/com/google/android"

    # Build DTB/DTBO
    echo "Building common exynos9830 Device Tree Blob Image..."
    ./toolchain/mkdtimg cfg_create "${output_dir}/dtb.img" build/dtconfigs/exynos9830.cfg \
        -d out/arch/arm64/boot/dts/exynos || print_error "DTB creation failed"

    echo "Building Device Tree Blob Output Image for $MODEL..."
    ./toolchain/mkdtimg cfg_create "${output_dir}/dtbo.img" build/dtconfigs/"${MODEL}".cfg \
        -d out/arch/arm64/boot/dts/samsung || print_error "DTBO creation failed"

    # Original RAMDisk and boot.img creation
    if [ -z "$RECOVERY" ]; then
        echo "Building RAMDisk..."
        pushd build/ramdisk >/dev/null
        find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip > "${output_dir}/ramdisk.cpio.gz"
        popd >/dev/null

        echo "Creating boot image..."
        ./toolchain/mkbootimg \
            --kernel out/arch/arm64/boot/Image \
            --base 0x10000000 \
            --pagesize 2048 \
            --board "${BOARD_MAP[$MODEL]}" \
            --cmdline 'androidboot.hardware=exynos990 loop.max_part=7' \
            --dtb "${output_dir}/dtb.img" \
            --ramdisk "${output_dir}/ramdisk.cpio.gz" \
            --ramdisk_offset 0x01000000 \
            --kernel_offset 0x00008000 \
            --dtb_offset 0x00000000 \
            --tags_offset 0x00000100 \
            --header_version 2 \
            --hashtype sha1 \
            --os_version "14.0.0" \
            --os_patch_level "2024-05" \
            --output "${output_dir}/boot.img"
    fi

    # ZIP packaging
    echo "Building zip..."
    cp "${output_dir}/boot.img" "${output_dir}/zip/files"
    cp "${output_dir}/dtbo.img" "${output_dir}/zip/files"
    cp build/update-binary build/updater-script "${output_dir}/zip/META-INF/com/google/android"

    pushd "${output_dir}/zip" >/dev/null
    local zip_name
    if [[ "${KSU_OPTION}" == "y" ]]; then
        zip_name="Eyeless_${version}_${MODEL}_KSU_${current_date}.zip"
    else
        zip_name="Eyeless_${version}_${MODEL}_${current_date}.zip"
    fi
    zip -qr "../${zip_name}" .
    popd >/dev/null

    echo -e "${GREEN}Package created: ${output_dir}/${zip_name}${NC}"
}

# Main execution
[[ $# -eq 0 ]] && show_help

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model) MODEL="$2"; shift 2 ;;
        -k|--ksu) KSU_OPTION="${2,,}"; shift 2 ;;
        -r|--recovery) RECOVERY_OPTION="${2,,}"; shift 2 ;;
        -c|--ccache) CCACHE_OPTION="${2,,}"; shift 2 ;;
        -f|--freq) FREQ_OPTION="${2,,}"; shift 2 ;;
        -e|--extra) EXTRA_CONFIGS=1; shift ;;
        --toggle)
            new_state=$((1 - $(<"${TOGGLE_FILE}" 2>/dev/null || echo 0)))
            echo "${new_state}" > "${TOGGLE_FILE}"
            echo "Toggled to $([ "${new_state}" -eq 1 ] && echo "ON" || echo "OFF")"
            exit 0 ;;
        -h|--help) show_help ;;
        *) print_error "Invalid option: $1" ;;
    esac
done

# Validate model
[ -z "$MODEL" ] && print_error "Model parameter required!"
[ -z "${BOARD_MAP[$MODEL]}" ] && print_error "Invalid model! Available: ${!BOARD_MAP[*]}"

# Prompt for KSU if not provided
if [ -z "$KSU_OPTION" ]; then
    read -p "Include KernelSU (y/N): " KSU_OPTION
    KSU_OPTION="${KSU_OPTION:-n}"
    KSU_OPTION="${KSU_OPTION,,}"
fi

# Initialize environment
setup_toolchain
handle_frequency
configure_ccache

# Configuration handling
[ "${RECOVERY_OPTION}" = "y" ] && { RECOVERY=1; KSU_OPTION="n"; }
[ "${KSU_OPTION}" = "y" ] && KSU=1

if [ -n "$EXTRA_CONFIGS" ]; then
    select_extra_configs
elif [ -f "$TOGGLE_FILE" ] && [ $(<"$TOGGLE_FILE") -eq 1 ] && [ -f "$CONFIG_SAVE_FILE" ]; then
    mapfile -t SELECTED_CONFIGS < "$CONFIG_SAVE_FILE"
fi

# Build process
build_kernel
package_bootimg

echo -e "${GREEN}Build completed successfully!${NC}"
