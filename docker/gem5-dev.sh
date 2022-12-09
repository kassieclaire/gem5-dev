#!/bin/bash
#
# This script is the front-end execution script for using the gem5-dev
# docker image. To use it, you would run a command like this:
#   docker run -v $GEM5_HOST_WORKDIR:/gem5 -it gem5-dev [<cmd>]
#
# Author: Artur Klauser

# Updated by: Kassie Povinelli
# Date: 11/09/2022
# Revised: 12/09/2022

#MOUNTDIR#  # substituted during docker build
mountdir=${mountdir:-'/gem5'}
readonly sourcedir="${mountdir}/source"
readonly systemdir="${mountdir}/system"

#DISK
readonly disk="ubuntu-18.04-arm64-docker.img"

print_usage() {
  cat << EOF
Usage: gem5-dev <cmd>
Where <cmd> is one of:
  help ............. prints this help message
  install-source ... installs the gem5 git source repository into ${sourcedir}
  update-source .... updates the gem5 git source repository in ${sourcedir}
  install-system ... installs the gem5 ARM system images in ${systemdir}
  build ............ builds gem5 ARM binary
  run-se ........... runs gem5 ARM in Syscall Emulation mode
  run-fs ........... runs gem5 ARM in Full System mode
  compile-program .. compiles a program for gem5 ARM
  cross-compile-program .. cross compiles a program for gem5 ARM (use if on x86)
  run-program-se ...... runs a program in gem5 ARM syscall emulation mode
  shell | bash ..... enters into an interactive shell
EOF
}

check_hostdir_mounted() {
  # The docker image contains a watermark file in ${mountdir} which will
  # only be visible when no volume is mounted.
  if [[ -e "${mountdir}/.in-docker-container" ]]; then
    cat << EOF
No host volume mounted to container's ${mountdir} directory.
Run:
  docker run -v \$GEM5_HOST_WORKDIR:${mountdir} -it gem5-dev [<cmd>]
EOF
    exit 1
  fi
}

# Clone gem5 source repository into ${sourcedir} if it isn't already there.
install_source() {
  check_hostdir_mounted
  if [ ! -e "${sourcedir}/.git" ]; then
    echo "installing gem5 source respository into ${sourcedir} ..."
    git clone https://gem5.googlesource.com/public/gem5 "${sourcedir}"
  else
    echo "gem5 source respository is already installed."
  fi
}

# Pull updates from gem5 source repository.
update_source() {
  check_hostdir_mounted
  if [[ -e "${sourcedir}/.git" ]]; then
    echo "updating gem5 source respository at ${sourcedir} ..."
    cd "${sourcedir}" || exit 1
    git pull
  else
    echo "gem5 source respository not found at ${sourcedir}."
  fi
}

# Download full system image if it isn't aleady there.
install_system() {
  check_hostdir_mounted
  echo "installing ARM full-system image into ${systemdir} ..."
  #if systemdir doesn't exist, create it
  if [ ! -d "${systemdir}" ]; then
    mkdir "${systemdir}"
  fi
  cd "${systemdir}" || exit 1
  #--- http://www.gem5.org/dist/current/arm/* disappeared on 2020-01-29.
  #--- Content is still visible at http://m5sim.org/dist/current/arm/.
  # local image='aarch-system-20180409.tar.xz'
  # echo "installing ARM full-system image $image"
  # wget -O - "http://www.gem5.org/dist/current/arm/${image}" | tar xJvf -
  #--- Using Pau's GitHub releases from 2018 instead.
  
  local image='aarch-system-20220707.tar.bz2'
  #check if the binaries are already downloaded
  #check if boot_emm.arm64 is in the directory binaries
  if [ ! -f "binaries/boot_emm.arm64" ]; then
      echo "installing ARM full-system image $image"
      local releases='http://dist.gem5.org/dist/v22-0/arm'
      wget -O - "${releases}/${image}" | tar xjvf -
      # Fix up image: ARM/dev/arm/RealView.py requires boot.arm64 to exist.
      ln -s 'boot_emm.arm64' 'binaries/boot.arm64'
  else
    echo "ARM full-system image is already installed."
  fi
  #check if the disk image is already downloaded
  #the disk image is in disks
  if [ ! -f "disks/${disk}" ]; then
    #change to the disks directory
    cd disks || exit 1
    echo "installing ARM disk image $disk"
      #download the latest linux disk image from http://dist.gem5.org/dist/v22-0/arm/disks/ubuntu-18.04-arm64-docker.img.bz2
    local releases='http://dist.gem5.org/dist/v22-0/arm/disks'
    #if compressed disk image doesn't exist, download it
    if [ ! -f "${disk}.bz2" ]; then
      wget "${releases}/${disk}.bz2"
    fi
    #unzip the disk image
    echo "unzipping disk image"
    lbzip2 -d "${disk}.bz2"
  else
    echo "ARM disk image is already installed."
  fi
}

# Builds the gem5 ARM binary.
build() {
  check_hostdir_mounted
  if [[ ! -e "${sourcedir}" ]]; then
    echo "gem5 source respository not found at ${sourcedir}."
    exit 1
  fi

  echo "building gem5 ARM binary ..."
  cd "${sourcedir}" || exit 1
  # Building inst-constrs-3.cc is a memory hog and can easily run the
  # container out of resources if done in parallel with other compiles. So
  # we first build it alone and then build the rest.
  #local cmd="/usr/bin/env python3 /usr/bin/scons build/ARM/arch/arm/generated/inst-constrs-3.o"
  #echo "${cmd}"
  #${cmd}
  # Now build the rest in parallel.
  cmd="/usr/bin/env python3 /usr/bin/scons -j $(nproc) build/ARM/gem5.opt"
  echo "${cmd}"
  ${cmd}
}

# Runs the gem5 ARM binary in Syscall Emulation mode.
run_se() {
  check_hostdir_mounted
  if [[ ! -e "${sourcedir}" ]]; then
    echo "gem5 source respository not found at ${sourcedir}."
    exit 1
  fi

  echo "running gem5 ARM binary in Syscall Emulation mode ..."
  cd "${sourcedir}" || exit 1
  local -r simulator='build/ARM/gem5.opt'
  local -r script='configs/example/se.py'
  local -r binary='tests/test-progs/hello/bin/arm/linux/hello'
  if [[ ! -e "${simulator}" ]]; then
    echo "gem5 simulator binary ${simulator} not found."
    exit 1
  fi
  local -r cmd="${simulator} ${script} -c ${binary}"
  echo "${cmd}"
  ${cmd}
}

# Runs the gem5 ARM binary in Full System mode.
run_fs() {
  check_hostdir_mounted
  if [[ ! -e "${sourcedir}" ]]; then
    echo "gem5 source respository not found at ${sourcedir}."
    exit 1
  fi
  if [[ ! -e "${systemdir}" ]]; then
    echo "gem5 ARM full system image not found at ${systemdir}."
    exit 1
  fi

  echo "running gem5 ARM binary in Full System mode ..."
  cd "${sourcedir}" || exit 1
  local -r simulator='build/ARM/gem5.opt'
  local -r script='configs/example/fs.py'

  if [[ ! -e "${simulator}" ]]; then
    echo "gem5 simulator binary ${simulator} not found."
    exit 1
  fi

  #legacy settings
  # local -r cmd="${simulator} ${script} \
  #   --machine-type=VExpress_GEM5_V1 \
  #   --dtb=armv8_gem5_v1_1cpu.dtb \
  #   --kernel=vmlinux.vexpress_gem5_v1_64 \
  #   --script=tests/halt.sh"
  # echo "${cmd}"

  #new settings
  local -r cmd="${simulator} ${script} \
    --machine-type=VExpress_GEM5_V2 \
    --kernel=vmlinux.arm64
    --script=tests/compiler-tests.sh \
    --disk-image=${systemdir}/disks/${disk}"
  ${cmd}
}

# Starts an interactive shell.
run_shell() {
  check_hostdir_mounted
  echo "To build gem5, run: "
  echo "  cd ${sourcedir}; /usr/bin/env python3 /usr/bin/scons -j \$(nproc) build/ARM/gem5.opt"
  cd "${mountdir}" || exit 1
  exec /bin/bash -l
}
#Compile a program given the compiler to use and its name as an argument
compile_program() {
  if [[ ! -e "${sourcedir}" ]]; then
    echo "gem5 source respository not found at ${sourcedir}."
    exit 1
  fi
  #change directory to the gem5 source directory
  cd "${sourcedir}" || exit 1
  #the program name is the first argument
  local -r program_name=$1
  #check the extension of the file. If it is cpp, use g++ to compile it. If it is c, use gcc to compile it.
  if [[ $program_name == *.cpp ]]; then
    local -r compiler="g++"
  elif [[ $program_name == *.c ]]; then
    local -r compiler="gcc"
  else
    echo "The file extension is not supported. Please use .cpp or .c"
    exit 1
  fi
  echo "compiling program ..."
  #if there are more arguments, include them in the compilation command. Otherwise, use the default compiler settings
  if [[ $# -gt 1 ]]; then
    local -r cmd="${compiler} ${program_name} -o ${program_name%.*} -static -Iinclude util/m5/src/abi/arm64/m5op.S ${@:2}"
  else
    local -r cmd="${compiler} ${program_name} -o ${program_name%.*} -static -Iinclude util/m5/src/abi/arm64/m5op.S -O3 -std=c++11"
  fi
  echo "${cmd}"
  ${cmd}
}
#cross-compile a program (same as compile_program, but with a different compiler for cross-compiling ARM on x86)
cross_compile_program() {
  if [[ ! -e "${sourcedir}" ]]; then
    echo "gem5 source respository not found at ${sourcedir}."
    exit 1
  fi
  #change directory to the gem5 source directory
  cd "${sourcedir}" || exit 1
  #the program name is the first argument
  local -r program_name=$1
  #check the extension of the file. If it is cpp, use g++ to compile it. If it is c, use gcc to compile it.
  if [[ $program_name == *.cpp ]]; then
    local -r compiler="arm-linux-gnueabihf-g++"
  elif [[ $program_name == *.c ]]; then
    local -r compiler="arm-linux-gnueabihf-gcc"
  else
    echo "The file extension is not supported. Please use .cpp or .c"
    exit 1
  fi
  echo "compiling program ..."
  #if there are more arguments, include them in the compilation command. Otherwise, use the default compiler settings
  if [[ $# -gt 1 ]]; then
    local -r cmd="${compiler} ${program_name} -o ${program_name%.*} -static -Iinclude util/m5/src/abi/arm64/m5op.S ${@:2}"
  else
    local -r cmd="${compiler} ${program_name} -o ${program_name%.*} -static -Iinclude util/m5/src/abi/arm64/m5op.S -O3 -std=c++11"
  fi
  echo "${cmd}"
  ${cmd}
}
#Run a program in syscall-emulation mode given its name as an argument
run_program_se() {
  check_hostdir_mounted
  if [[ ! -e "${sourcedir}" ]]; then
    echo "gem5 source respository not found at ${sourcedir}."
    exit 1
  fi
  echo "running gem5 ARM binary in Syscall Emulation mode ..."
  cd "${sourcedir}" || exit 1
  local -r simulator='build/ARM/gem5.opt'
  local -r script='configs/example/se.py'
  local -r binary=$1
  if [[ ! -e "${simulator}" ]]; then
    echo "gem5 simulator binary ${simulator} not found."
    exit 1
  fi
  #if there is no binary with the given name, exit
  if [[ ! -e "${binary}" ]]; then
    echo "binary ${binary} not found."
    exit 1
  fi
  #if there are more arguments, include them in the compilation command. Otherwise, run the binary without any arguments
  if [[ $# -gt 1 ]]; then
    #put the args in a string and pass it to the command
    local -r args=${@:2}
    #echo "${args}"
    echo "running ${binary} with arguments ${args}"
    local -r cmd="${simulator} ${script} -c ${binary} ${args}"
  else
    local -r cmd="${simulator} ${script} -c ${binary}"
  fi
  #echo the command and run it
  echo "${cmd}"
  ${cmd}
}


main() {
  local cmd
  local -r initial_dir="${PWD}"
  
  #check to see what command was given. If it is a valid command, run it and pass the rest of the arguments to it. Otherwise, print an error message and the usage
  #the command is the first argument after gem5-dev
  #the rest of the arguments are passed to the function
  cmd="${1}"
  shift
  
  case "${cmd}" in
    'help') print_usage ;;
    'install-source') install_source $@;;
    'update-source') update_source $@;;
    'install-system') install_system $@;;
    'build') build $@;;
    'run-se') run_se $@;;
    'run-fs') run_fs $@;;
    'compile-program' ) compile_program $@;;
    'cross-compile-program' ) cross_compile_program $@;;
    'run-program-se' ) run_program_se $@;;
    'shell' | 'bash') run_shell $@;;
    -* | +*) set "${cmd}" ;; # pass +/-flags to shell's set command.
    *)
      echo "unkown command '${cmd}'"
      echo
      print_usage
      exit 1
      ;;
  esac
  cd "${initial_dir}" || exit 1
  #done
}

main "$@"
