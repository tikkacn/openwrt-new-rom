FROM ubuntu:22.04
# 设置非交互式安装
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai
# 安装必要的依赖包（添加了sudo）
RUN apt-get update && apt-get install -y \
    sudo ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
    bzip2 ccache cmake cpio curl device-tree-compiler fastjar flex gawk gettext \
    gcc-multilib g++-multilib git gperf haveged help2man intltool libc6-dev-i386 \
    libelf-dev libglib2.0-dev libgmp3-dev libltdl-dev libmpc-dev libmpfr-dev \
    libncurses5-dev libncursesw5-dev libreadline-dev libssl-dev libtool lrzsz \
    mkisofs msmtp nano ninja-build p7zip p7zip-full patch pkgconf python2.7 python3 \
    python3-pyelftools libpython3-dev qemu-utils rsync scons squashfs-tools subversion \
    swig texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev \
    python3-setuptools jq bc lm-sensors pciutils \
    clang llvm lld zip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
# 创建工作目录
WORKDIR /workdir
# 初始化环境变量
ENV FORCE_UNSAFE_CONFIGURE=1
# 预创建必要的目录结构
RUN mkdir -p /workdir/ccache /workdir/build_state /workdir/firmware
# 设置CCACHE
RUN mkdir -p /workdir/ccache && \
    ccache -o cache_dir=/workdir/ccache && \
    ccache -o max_size=8G

# 安装sudo
RUN apt-get update && apt-get install -y sudo && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 确保用户ID为1000 (通常是GitHub Actions的用户ID)
RUN groupadd -g 1000 builder && \
    useradd -u 1000 -g 1000 -m builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# 工作目录权限设置
RUN chmod -R 777 /workdir
CMD ["/bin/bash"]
