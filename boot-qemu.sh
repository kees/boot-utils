#!/usr/bin/env bash

# Root of the repo
BASE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

source "${BASE}"/utils.sh

# Check that a binary is found
function checkbin() {
    command -v "${1}" &>/dev/null || die "${1} could not be found, please install it!"
}

# Parse inputs to the script
function parse_parameters() {
    while ((${#})); do
        case ${1} in
            -a | --arch | --architecture)
                shift
                case ${1} in
                    arm | arm32_v5 | arm32_v6 | arm32_v7 | arm64 | arm64be | m68k | mips | mipsel | ppc32 | ppc32_mac | ppc64 | ppc64le | riscv | s390 | x86 | x86_64) ARCH=${1} ;;
                    *) die "Invalid --arch value '${1}'" ;;
                esac
                ;;

            -d | --debug)
                set -x
                ;;

            --debian)
                DEBIAN=true
                INTERACTIVE=true
                ;;

            -g | --gdb)
                GDB=true
                INTERACTIVE=true
                ;;

            -h | --help)
                echo
                cat "${BASE}"/README.txt
                echo
                exit 0
                ;;

            -i | --interactive | --shell)
                INTERACTIVE=true
                ;;

            -k | --kernel-location)
                shift && KERNEL_LOCATION=${1}
                ;;

            --no-kvm)
                KVM=false
                ;;

            -s | --smp)
                shift && SMP=${1}
                ;;

            -t | --timeout)
                shift && TIMEOUT=${1}
                ;;

            *)
                die "Invalid parameter '${1}'"
                ;;
        esac
        shift
    done
}

# Sanity check parameters and required tools
function sanity_check() {
    # Kernel build folder and architecture are required paramters
    [[ -z ${ARCH} ]] && die "Architecture ('-a') is required but not specified!"
    [[ -z ${KERNEL_LOCATION} ]] && die "Kernel image or kernel build folder ('-k') is required but not specified!"

    # Some default values
    [[ -z ${DEBIAN} ]] && DEBIAN=false
    [[ -z ${INTERACTIVE} ]] && INTERACTIVE=false
    [[ -z ${KVM} ]] && KVM=true

    # KERNEL_LOCATION could be a relative path; turn it into an absolute one with readlink
    KERNEL_LOCATION=$(readlink -f "${KERNEL_LOCATION}")

    # Make sure zstd is install
    checkbin zstd
}

function get_default_smp_value() {
    # KERNEL_LOCATION is either a path to the kernel source or a full kernel
    # location. If it is a file, we need to strip off the basename so that we
    # can easily navigate around with '..'.
    if [[ -f ${KERNEL_LOCATION} ]]; then
        KERNEL_DIRNAME=$(dirname "${KERNEL_LOCATION}")
    else
        KERNEL_DIRNAME=${KERNEL_LOCATION}
    fi

    # If KERNEL_LOCATION is the kernel source, the configuration will be at
    # ${KERNEL_DIRNAME}/.config
    #
    # If KERNEL_LOCATION is a full kernel location, it could either be:
    #   * ${KERNEL_DIRNAME}/.config (if the image is vmlinux)
    #   * ${KERNEL_DIRNAME}/../../../.config (if the image is in arch/*/boot/)
    #   * ${KERNEL_DIRNAME}/config (if the image is in a TuxMake folder)
    for CONFIG_LOCATION in .config ../../../.config config; do
        CONFIG_FILE=$(readlink -f "${KERNEL_DIRNAME}/${CONFIG_LOCATION}")
        if [[ -f ${CONFIG_FILE} ]]; then
            HAS_CONFIG=true
            break
        fi
    done

    if ${HAS_CONFIG:=false}; then
        CONFIG_NR_CPUS=$(grep "^CONFIG_NR_CPUS=" "${CONFIG_FILE}" | cut -d= -f2)
    fi

    if [[ -z ${CONFIG_NR_CPUS} ]]; then
        # Sensible default value based on treewide defaults for CONFIG_NR_CPUS.
        CONFIG_NR_CPUS=8
    fi

    # Use the minimum of the number of processors in the system or
    # CONFIG_NR_CPUS.
    CPUS=$(nproc)
    if [[ ${CPUS} -gt ${CONFIG_NR_CPUS} ]]; then
        echo "${CONFIG_NR_CPUS}"
    else
        echo "${CPUS}"
    fi
}

# Takes a version (x.y.z) and prints a six or seven digit number
# For example, QEMU 6.2.50 would become 602050 and Linux 5.10.100
# would become 510100
function print_ver_code() {
    IFS=. read -ra VER_CODE <<<"${1}"
    printf "%d%02d%03d" "${VER_CODE[@]}"
}

# Print QEMU version as a six or seven digit number
function get_qemu_ver_code() {
    print_ver_code "$("${QEMU[@]}" --version | head -1 | cut -d ' ' -f 4)"
}

# Print Linux version of a kernel image as a six or seven digit number
# Takes the command to dump a kernel image to stdout as its argument
function get_lnx_ver_code() {
    print_ver_code "$("${@}" |& strings |& grep -E "^Linux version [0-9]\.[0-9]+\.[0-9]+" | cut -d ' ' -f 3 | cut -d - -f 1)"
}

# Boot QEMU
function setup_qemu_args() {
    # All arm32_* options share the same rootfs, under images/arm
    [[ ${ARCH} =~ arm32 ]] && ARCH_RTFS_DIR=arm
    # All ppc32_* options share the same rootfs, under images/ppc32
    [[ ${ARCH} =~ ppc32 ]] && ARCH_RTFS_DIR=ppc32

    IMAGES_DIR=${BASE}/images/${ARCH_RTFS_DIR:-${ARCH}}
    if ${DEBIAN}; then
        ROOTFS=${IMAGES_DIR}/debian.img
        [[ -f ${ROOTFS} ]] || die "'--debian' requires a debian.img. Run 'sudo debian/build.sh -a ${IMAGES_DIR##*/}' to generate it."
    else
        ROOTFS=${IMAGES_DIR}/rootfs.cpio
    fi

    APPEND_STRING=""
    if ${INTERACTIVE}; then
        if ${DEBIAN}; then
            APPEND_STRING+="root=/dev/vda "
        else
            APPEND_STRING+="rdinit=/bin/sh "
        fi
    fi
    if ${GDB:=false}; then
        APPEND_STRING+="nokaslr "
    fi

    case ${ARCH} in
        arm32_v5)
            APPEND_STRING+="earlycon "
            ARCH=arm
            DTB=aspeed-bmc-opp-palmetto.dtb
            QEMU_ARCH_ARGS=(
                -machine palmetto-bmc
            )
            QEMU=(qemu-system-arm)
            ;;

        arm32_v6)
            ARCH=arm
            DTB=aspeed-bmc-opp-romulus.dtb
            QEMU_ARCH_ARGS=(
                -machine romulus-bmc
            )
            QEMU=(qemu-system-arm)
            ;;

        arm | arm32_v7)
            ARCH=arm
            APPEND_STRING+="console=ttyAMA0 earlycon "
            # https://lists.nongnu.org/archive/html/qemu-discuss/2018-08/msg00030.html
            # VFS: Cannot open root device "vda" or unknown-block(0,0): error -6
            ${DEBIAN} && HIGHMEM=,highmem=off
            QEMU_ARCH_ARGS=(
                -machine "virt${HIGHMEM}"
            )
            # It is possible to boot ARMv7 kernels under KVM on AArch64 hosts,
            # if it is supported. ARMv7 KVM support was ripped out of the
            # kernel in 5.7 so we don't even bother checking.
            if [[ "$(uname -m)" = "aarch64" && -e /dev/kvm ]] && ${KVM} &&
                "${BASE}"/utils/aarch64_32_bit_el1_supported; then
                QEMU_ARCH_ARGS+=(
                    -cpu "host,aarch64=off"
                    -enable-kvm
                    -smp "${SMP:-$(get_default_smp_value)}"
                )
                QEMU=(qemu-system-aarch64)
            else
                QEMU=(qemu-system-arm)
            fi
            ;;

        arm64 | arm64be)
            ARCH=arm64
            KIMAGE=Image.gz
            QEMU=(qemu-system-aarch64)
            APPEND_STRING+="console=ttyAMA0 earlycon "
            QEMU_ARCH_ARGS=(-machine "virt,gic-version=max")
            if [[ "$(uname -m)" = "aarch64" && -e /dev/kvm ]] && ${KVM}; then
                QEMU_ARCH_ARGS+=(
                    -cpu host
                    -enable-kvm
                    -smp "${SMP:-$(get_default_smp_value)}"
                )
            else
                get_full_kernel_path
                QEMU_VER_CODE=$(get_qemu_ver_code)
                if [[ ${QEMU_VER_CODE} -ge 602050 ]]; then
                    LNX_VER_CODE=$(get_lnx_ver_code gzip -c -d "${KERNEL}")
                    # https://gitlab.com/qemu-project/qemu/-/issues/964
                    if [[ ${LNX_VER_CODE} -lt 416000 ]]; then
                        CPU=cortex-a72
                    # lpa2=off: https://gitlab.com/qemu-project/qemu/-/commit/69b2265d5fe8e0f401d75e175e0a243a7d505e53
                    # pauth-impdef=true: https://lore.kernel.org/YlgVa+AP0g4IYvzN@lakrids/
                    elif [[ ${LNX_VER_CODE} -lt 512000 ]]; then
                        CPU=max,lpa2=off,pauth-impdef=true
                    fi
                fi
                if [[ -z ${CPU} ]]; then
                    CPU=max
                    # https://lore.kernel.org/YlgVa+AP0g4IYvzN@lakrids/
                    [[ ${QEMU_VER_CODE} -ge 600000 ]] && CPU=${CPU},pauth-impdef=true
                fi
                QEMU_ARCH_ARGS+=(
                    -cpu "${CPU}"
                    -machine "virtualization=true"
                )
            fi
            # Give the machine more cores and memory when booting Debian to
            # improve performance
            if ${DEBIAN}; then
                QEMU_RAM=2G
                # Do not add '-smp' if it is present at this point, as that
                # means that KVM is being used, which will already have a
                # suitable number of cores
                if ! echo "${QEMU_ARCH_ARGS[*]}" | grep -q smp; then
                    QEMU_ARCH_ARGS+=(-smp "${SMP:-4}")
                fi
            fi
            ;;

        m68k)
            APPEND_STRING+="console=ttyS0,115200 "
            KIMAGE=vmlinux
            QEMU_ARCH_ARGS=(
                -cpu m68040
                -M q800
            )
            QEMU=(qemu-system-m68k)
            ;;

        mips | mipsel)
            KIMAGE=vmlinux
            QEMU_ARCH_ARGS=(
                -cpu 24Kf
                -machine malta
            )
            QEMU=(qemu-system-"${ARCH}")
            ARCH=mips
            ;;

        ppc32 | ppc32_mac)
            case ${ARCH} in
                ppc32)
                    KIMAGE=uImage
                    QEMU_ARCH_ARGS=(-machine bamboo)
                    ;;
                ppc32_mac)
                    KIMAGE=vmlinux
                    QEMU_ARCH_ARGS=(-machine mac99)
                    ;;
            esac
            ARCH=powerpc
            APPEND_STRING+="console=ttyS0 "
            QEMU_RAM=128m
            QEMU=(qemu-system-ppc)
            ;;

        ppc64)
            ARCH=powerpc
            KIMAGE=vmlinux
            QEMU_ARCH_ARGS=(
                -cpu power8
                -machine pseries
                -vga none
            )
            QEMU_RAM=1G
            QEMU=(qemu-system-ppc64)
            ;;

        ppc64le)
            ARCH=powerpc
            KIMAGE=zImage.epapr
            QEMU_ARCH_ARGS=(
                -device "ipmi-bmc-sim,id=bmc0"
                -device "isa-ipmi-bt,bmc=bmc0,irq=10"
                -L "${IMAGES_DIR}/" -bios skiboot.lid
                -machine powernv8
            )
            QEMU_RAM=2G
            QEMU=(qemu-system-ppc64)
            ;;

        riscv)
            APPEND_STRING+="earlycon "
            KIMAGE=Image
            DEB_BIOS=/usr/lib/riscv64-linux-gnu/opensbi/qemu/virt/fw_jump.elf
            [[ -f ${DEB_BIOS} && -z ${BIOS} ]] && BIOS=${DEB_BIOS}
            QEMU_ARCH_ARGS=(
                -bios "${BIOS:-default}"
                -M virt
            )
            QEMU=(qemu-system-riscv64)
            ;;

        s390)
            KIMAGE=bzImage
            QEMU_ARCH_ARGS=(-M s390-ccw-virtio)
            QEMU=(qemu-system-s390x)
            ;;

        x86 | x86_64)
            KIMAGE=bzImage
            APPEND_STRING+="console=ttyS0 earlycon=uart8250,io,0x3f8 "
            # Use KVM if the processor supports it and the KVM module is loaded (i.e. /dev/kvm exists)
            if [[ $(grep -c -E 'vmx|svm' /proc/cpuinfo) -gt 0 && -e /dev/kvm ]] && ${KVM}; then
                QEMU_ARCH_ARGS=(
                    -cpu host
                    -d "unimp,guest_errors"
                    -enable-kvm
                    -smp "${SMP:-$(get_default_smp_value)}"
                )
            else
                [[ ${ARCH} = "x86_64" ]] && QEMU_ARCH_ARGS=(-cpu Nehalem)
            fi
            case ${ARCH} in
                x86) QEMU=(qemu-system-i386) ;;
                x86_64) QEMU=(qemu-system-x86_64) ;;
            esac
            ;;
    esac
    checkbin "${QEMU[*]}"

    [[ -z ${KERNEL} ]] && get_full_kernel_path

    if [[ -n ${DTB} ]]; then
        # If we are in a boot folder, look for them in the dts folder in it
        if [[ $(basename "${KERNEL%/*}") = "boot" ]]; then
            DTB_FOLDER=dts/
        # Otherwise, assume there is a dtbs folder in the same folder as the kernel image (tuxmake)
        else
            DTB_FOLDER=dtbs/
        fi
        DTB=${KERNEL%/*}/${DTB_FOLDER}${DTB}
        [[ -f ${DTB} ]] || die "${DTB##*/} is required for booting but it could not be found at ${DTB}!"
        QEMU_ARCH_ARGS+=(-dtb "${DTB}")
    fi
}

# Invoke QEMU
function invoke_qemu() {
    green "QEMU location: " "$(dirname "$(command -v "${QEMU[*]}")")" '\n'
    green "QEMU version: " "$("${QEMU[@]}" --version | head -n1)" '\n'

    [[ -z ${QEMU_RAM} ]] && QEMU_RAM=512m
    if ${DEBIAN}; then
        QEMU+=(-drive "file=${ROOTFS},format=raw,if=virtio,index=0,media=disk")
    else
        rm -rf "${ROOTFS}"
        zstd -q -d "${ROOTFS}".zst -o "${ROOTFS}"
        QEMU+=(-initrd "${ROOTFS}")
    fi
    # Removing trailing space for aesthetic purposes
    [[ -n ${APPEND_STRING} ]] && QEMU+=(-append "${APPEND_STRING%* }")
    if [[ -n ${SMP} ]] && ! echo "${QEMU_ARCH_ARGS[*]}" | grep -q "smp"; then
        QEMU+=(-smp "${SMP}")
    fi
    if ${GDB:=false}; then
        while true; do
            if lsof -i:1234 &>/dev/null; then
                red "Port :1234 already bound to. QEMU already running?"
                exit 1
            fi
            green "Starting QEMU with GDB connection on port 1234..."
            # Note: no -serial mon:stdio
            "${QEMU[@]}" \
                "${QEMU_ARCH_ARGS[@]}" \
                -display none \
                -kernel "${KERNEL}" \
                -m "${QEMU_RAM}" \
                -nodefaults \
                -s -S &
            QEMU_PID=$!
            green "Starting GDB..."
            "${GDB_BIN:-gdb-multiarch}" "${KERNEL_LOCATION}/vmlinux" \
                -ex "target remote :1234"
            red "Killing QEMU..."
            kill -9 "${QEMU_PID}"
            wait "${QEMU_PID}" 2>/dev/null
            while true; do
                read -rp "Rerun [Y/n/?] " yn
                case $yn in
                    [Yy]*) break ;;
                    [Nn]*) exit 0 ;;
                    *) break ;;
                esac
            done
        done
    fi

    ${INTERACTIVE} || QEMU=(timeout --foreground "${TIMEOUT:=3m}" stdbuf -oL -eL "${QEMU[@]}")
    set -x
    "${QEMU[@]}" \
        "${QEMU_ARCH_ARGS[@]}" \
        -no-reboot \
        -display none \
        -kernel "${KERNEL}" \
        -m "${QEMU_RAM}" \
        -nodefaults \
        -serial mon:stdio
    RET=${?}
    set +x

    return ${RET}
}

parse_parameters "${@}"
sanity_check
setup_qemu_args
invoke_qemu
