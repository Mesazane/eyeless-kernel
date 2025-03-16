#!/bin/bash

CONFIG_SAVE_FILE="saved_options_defconfig"
TOGGLE_FILE="use_extra_configs.toggle"

unset_flags() {
    cat << EOF
Usage: $(basename "$0") [options]
Options:
    -m, --model [value]    Specify the model code of the phone
    -k, --ksu [y/N]        Include KernelSU
    -r, --recovery [y/N]   Compile kernel for an Android Recovery
    -c, --ccache [y/N]     Use ccache to cache compilations
    -f, --freq [value]     Set CPU frequency (underclocked, overclocked, original)
    -e, --extra-configs    Enable extra configuration selection
    --toggle               Toggle the usage of extra configurations (change between 0 and 1)
EOF
    exit 1
}

if [[ $# -eq 0 ]]; then
    if [[ -f "$TOGGLE_FILE" && $(cat "$TOGGLE_FILE") -eq 1 ]]; then
        echo "-----------------------------------------------"
        echo "EXTRA CONFIGURATIONS: ON"
        echo "-----------------------------------------------"
    else
        echo "-----------------------------------------------"
        echo "EXTRA CONFIGURATIONS: OFF"
        echo "-----------------------------------------------"
    fi
    unset_flags
fi

EXTRA_CONFIGS_ENABLED="n"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model|-m)
            MODEL="$2"
            shift 2
            ;;
        --ksu|-k)
            KSU_OPTION="$2"
            shift 2
            ;;
        --recovery|-r)
            RECOVERY_OPTION="$2"
            shift 2
            ;;
        --ccache|-c)
            CCACHE_OPTION="$2"
            shift 2
            ;;
        --freq|-f)
            FREQ_OPTION="$2"
            shift 2
            ;;
        --extra-configs|-e)
            EXTRA_CONFIGS_ENABLED="y"
            shift
            ;;
        --toggle)
            if [[ -f "$TOGGLE_FILE" ]]; then
                if [[ $(cat "$TOGGLE_FILE") -eq 1 ]]; then
                    echo "0" > "$TOGGLE_FILE"
                    echo "Toggled to OFF (extra configurations disabled)"
                else
                    echo "1" > "$TOGGLE_FILE"
                    echo "Toggled to ON (extra configurations enabled)"
                fi
            else
                echo "1" > "$TOGGLE_FILE"
                echo "Created $TOGGLE_FILE and set to ON (extra configurations enabled)"
            fi
            exit 0
            ;;
        *)
            unset_flags
            ;;
    esac
done

echo "Preparing the build environment..."

pushd "$(dirname "$0")" > /dev/null
CORES=$(grep -c processor /proc/cpuinfo)

# Define toolchain variables
CLANG_DIR=$PWD/toolchain/neutron_18
PATH=$CLANG_DIR/bin:$PATH

# Check if toolchain exists
if [ ! -f "$CLANG_DIR/bin/clang-18" ]; then
    echo "-----------------------------------------------"
    echo "Toolchain not found! Downloading..."
    echo "-----------------------------------------------"
    rm -rf "$CLANG_DIR"
    mkdir -p "$CLANG_DIR"
    pushd toolchain/neutron_18 > /dev/null
    bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") -S=05012024
    echo "-----------------------------------------------"
    echo "Patching toolchain..."
    echo "-----------------------------------------------"
    bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") --patch=glibc
    echo "-----------------------------------------------"
    echo "Cleaning up..."
    popd > /dev/null
fi

if [[ "$CCACHE_OPTION" == "y" ]]; then
    CCACHE=ccache
fi

MAKE_ARGS="
LLVM=1 \
LLVM_IAS=1 \
ARCH=arm64 \
CCACHE=$CCACHE \
READELF=$CLANG_DIR/bin/llvm-readelf \
O=out
"

KERNEL_DEFCONFIG=eyeless_"$MODEL"_defconfig
case $MODEL in
    x1slte)
        BOARD=SRPSJ28B018KU
        ;;
    x1s)
        BOARD=SRPSI19A018KU
        ;;
    y2slte)
        BOARD=SRPSJ28A018KU
        ;;
    y2s)
        BOARD=SRPSG12A018KU
        ;;
    z3s)
        BOARD=SRPSI19B018KU
        ;;
    c1slte)
        BOARD=SRPTC30B009KU
        ;;
    c1s)
        BOARD=SRPTB27D009KU
        ;;
    c2slte)
        BOARD=SRPTC30A009KU
        ;;
    c2s)
        BOARD=SRPTB27C009KU
        ;;
    r8s)
        BOARD=SRPTF26B014KU
        ;;
    *)
        unset_flags
        exit
        ;;
esac

if [[ "$RECOVERY_OPTION" == "y" ]]; then
    RECOVERY=recovery.config
    KSU_OPTION=n
fi

if [ -z "$KSU_OPTION" ]; then
    read -p "Include KernelSU (y/N): " KSU_OPTION
fi

if [[ "$KSU_OPTION" == "y" ]]; then
    KSU=ksu.config
fi

select_extra_configs() {
    echo "-----------------------------------------------"
    echo "Select Extra Configurations to Merge:"
    echo "-----------------------------------------------"

    EXTRA_DIR="Extra"
    mapfile -t EXTRA_FILES < <(ls "$EXTRA_DIR"/*.config 2>/dev/null)

    if [[ ${#EXTRA_FILES[@]} -eq 0 ]]; then
        echo "No extra configurations found in $EXTRA_DIR"
        return
    fi

    SELECTED_CONFIGS=()

    while true; do
        echo "Available Extra Configs:"
        for i in "${!EXTRA_FILES[@]}"; do
            printf "[%2d] %s\n" "$((i+1))" "$(basename "${EXTRA_FILES[$i]}")"
        done
        echo "[ A ] Add all"
        echo "[ R ] Remove selected"
        echo "[ D ] Done selecting"
        echo "-----------------------------------------------"
        read -p "Enter number(s) of config(s) to add/remove, 'A' to add all, 'R' to remove, or 'D' to finish: " CHOICE

        case "$CHOICE" in
            [0-9]*)
                for num in $CHOICE; do
                    INDEX=$((num-1))
                    if [[ $INDEX -ge 0 && $INDEX -lt ${#EXTRA_FILES[@]} ]]; then
                        if [[ " ${SELECTED_CONFIGS[*]} " =~ " ${EXTRA_FILES[$INDEX]} " ]]; then
                            echo "Already added: $(basename "${EXTRA_FILES[$INDEX]}")"
                        else
                            SELECTED_CONFIGS+=("${EXTRA_FILES[$INDEX]}")
                            echo "Added: $(basename "${EXTRA_FILES[$INDEX]}")"
                        fi
                    else
                        echo "Invalid selection: $num"
                    fi
                done
                ;;
            A|a)
                SELECTED_CONFIGS=("${EXTRA_FILES[@]}")
                echo "Added all configurations!"
                break
                ;;
            R|r)
                if [[ ${#SELECTED_CONFIGS[@]} -eq 0 ]]; then
                    echo "No configs selected yet."
                else
                    echo "Currently Selected Configs:"
                    for i in "${!SELECTED_CONFIGS[@]}"; do
                        printf "[%2d] %s\n" "$((i+1))" "$(basename "${SELECTED_CONFIGS[$i]}")"
                    done
                    read -p "Enter the number(s) to remove: " REMOVE_CHOICE
                    for num in $REMOVE_CHOICE; do
                        INDEX=$((num-1))
                        if [[ $INDEX -ge 0 && $INDEX -lt ${#SELECTED_CONFIGS[@]} ]]; then
                            echo "Removed: $(basename "${SELECTED_CONFIGS[$INDEX]}")"
                            unset "SELECTED_CONFIGS[$INDEX]"
                            SELECTED_CONFIGS=("${SELECTED_CONFIGS[@]}")
                        else
                            echo "Invalid selection: $num"
                        fi
                    done
                fi
                ;;
            D|d)
                break
                ;;
            *)
                echo "Invalid option! Please select again."
                ;;
        esac
    done

    # Save selected configs to file
    echo "${SELECTED_CONFIGS[@]}" > "$CONFIG_SAVE_FILE"
}

if [[ "$EXTRA_CONFIGS_ENABLED" == "y" ]]; then
    select_extra_configs  # Populates SELECTED_CONFIGS and saves to file
fi

SELECTED_CONFIGS=()
if [[ -f "$TOGGLE_FILE" && $(cat "$TOGGLE_FILE") -eq 1 ]]; then
    echo "-----------------------------------------------"
    echo "EXTRA CONFIGURATIONS: ON (using saved selections)"
    echo "-----------------------------------------------"
    if [[ "$EXTRA_CONFIGS_ENABLED" != "y" && -f "$CONFIG_SAVE_FILE" ]]; then
        mapfile -t SELECTED_CONFIGS < "$CONFIG_SAVE_FILE"
    fi
else
    echo "-----------------------------------------------"
    echo "EXTRA CONFIGURATIONS: OFF"
    echo "-----------------------------------------------"
fi

echo "-----------------------------------------------"
echo "Building kernel using $KERNEL_DEFCONFIG"
if [[ ${#SELECTED_CONFIGS[@]} -gt 0 ]]; then
    echo "Applying extra configs:"
    for cfg in "${SELECTED_CONFIGS[@]}"; do
        echo "- $(basename "$cfg")"
    done
fi

# Build kernel configuration
make ${MAKE_ARGS} -j$CORES $KERNEL_DEFCONFIG eyeless.config "${SELECTED_CONFIGS[@]}" ${RECOVERY:-} ${KSU:-} || exit 1

echo "Building kernel..."
make ${MAKE_ARGS} -j$CORES 2>&1 | tee build.log || exit 1

# --- Create output directories if they don't exist ---
rm -rf build/out/"$MODEL"
mkdir -p build/out/"$MODEL"/zip/files
mkdir -p build/out/"$MODEL"/zip/META-INF/com/google/android

# Define constant variables
DTB_PATH=build/out/"$MODEL"/dtb.img
KERNEL_PATH=build/out/"$MODEL"/Image
KERNEL_OFFSET=0x00008000
DTB_OFFSET=0x00000000
RAMDISK_OFFSET=0x01000000
SECOND_OFFSET=0xF0000000
TAGS_OFFSET=0x00000100
BASE=0x10000000
CMDLINE='androidboot.hardware=exynos990 loop.max_part=7'
HASHTYPE=sha1
HEADER_VERSION=2
OS_PATCH_LEVEL=2024-05
OS_VERSION=14.0.0
PAGESIZE=2048
RAMDISK=build/out/"$MODEL"/ramdisk.cpio.gz
OUTPUT_FILE=build/out/"$MODEL"/boot.img

## Build auxiliary boot.img files
# Copy kernel image to output directory
cp out/arch/arm64/boot/Image build/out/"$MODEL"/ || exit 1

# Build dtb
echo "Building common exynos9830 Device Tree Blob Image..."
echo "-----------------------------------------------"
./toolchain/mkdtimg cfg_create build/out/"$MODEL"/dtb.img build/dtconfigs/exynos9830.cfg -d out/arch/arm64/boot/dts/exynos || exit 1

# Build dtbo
echo "Building Device Tree Blob Output Image for $MODEL..."
echo "-----------------------------------------------"
./toolchain/mkdtimg cfg_create build/out/"$MODEL"/dtbo.img build/dtconfigs/"$MODEL".cfg -d out/arch/arm64/boot/dts/samsung || exit 1

if [ -z "$RECOVERY" ]; then
    # Build ramdisk
    echo "Building RAMDisk..."
    echo "-----------------------------------------------"
    pushd build/ramdisk > /dev/null
        find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip > ../out/"$MODEL"/ramdisk.cpio.gz || exit 1
    popd > /dev/null
    echo "-----------------------------------------------"

    # Create boot image
    echo "Creating boot image..."
    echo "-----------------------------------------------"
    ./toolchain/mkbootimg --base $BASE --board $BOARD --cmdline "$CMDLINE" --dtb $DTB_PATH \
      --dtb_offset $DTB_OFFSET --hashtype $HASHTYPE --header_version $HEADER_VERSION --kernel $KERNEL_PATH \
      --kernel_offset $KERNEL_OFFSET --os_patch_level $OS_PATCH_LEVEL --os_version $OS_VERSION --pagesize $PAGESIZE \
      --ramdisk $RAMDISK --ramdisk_offset $RAMDISK_OFFSET \
      --second_offset $SECOND_OFFSET --tags_offset $TAGS_OFFSET -o $OUTPUT_FILE || exit 1

    # Build zip
    echo "Building zip..."
    echo "-----------------------------------------------"
    cp build/out/"$MODEL"/boot.img build/out/"$MODEL"/zip/files/boot.img || exit 1
    cp build/out/"$MODEL"/dtbo.img build/out/"$MODEL"/zip/files/dtbo.img || exit 1
    cp build/update-binary build/out/"$MODEL"/zip/META-INF/com/google/android/update-binary || exit 1
    cp build/updater-script build/out/"$MODEL"/zip/META-INF/com/google/android/updater-script || exit 1

    version=$(grep -o 'CONFIG_LOCALVERSION="[^"]*"' arch/arm64/configs/eyeless.config | cut -d '"' -f 2)
    version=${version:1}
    pushd build/out/"$MODEL"/zip > /dev/null
    DATE=$(date +"%d-%m-%Y_%H-%M-%S")

    if [[ "$KSU_OPTION" == "y" ]]; then
        NAME="$version"_"$MODEL"_UNOFFICIAL_KSU_"$DATE".zip
    else
        NAME="$version"_"$MODEL"_UNOFFICIAL_"$DATE".zip
    fi
    zip -r -qq ../"$NAME" . || exit 1
    popd > /dev/null
fi

popd > /dev/null
echo "Build finished successfully!"
