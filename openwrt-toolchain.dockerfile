# 文件一：Dockerfile（保存为openwrt-toolchain.dockerfile）
FROM ubuntu:22.04

# 设置非交互式安装
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# 安装必要的依赖包
RUN apt-get update && apt-get install -y \
    ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
    bzip2 ccache cmake cpio curl device-tree-compiler fastjar flex gawk gettext \
    gcc-multilib g++-multilib git gperf haveged help2man intltool libc6-dev-i386 \
    libelf-dev libglib2.0-dev libgmp3-dev libltdl-dev libmpc-dev libmpfr-dev \
    libncurses5-dev libncursesw5-dev libreadline-dev libssl-dev libtool lrzsz \
    mkisofs msmtp nano ninja-build p7zip p7zip-full patch pkgconf python2.7 python3 \
    python3-pyelftools libpython3-dev qemu-utils rsync scons squashfs-tools subversion \
    swig texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev \
    python3-setuptools jq bc lm-sensors pciutils \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 创建工作目录
WORKDIR /workdir

# 初始化环境变量
ENV FORCE_UNSAFE_CONFIGURE=1

# 预创建必要的目录结构
RUN mkdir -p /workdir/ccache /workdir/build_state

# 设置CCACHE
RUN mkdir -p /workdir/ccache && \
    ccache -o cache_dir=/workdir/ccache && \
    ccache -o max_size=8G

# 工作目录权限设置
RUN chmod -R 777 /workdir

# 创建entrypoint脚本
RUN echo '#!/bin/bash\n\
echo "OpenWrt构建环境已准备就绪"\n\
echo "当前目录: $(pwd)"\n\
echo "可用的命令:"\n\
echo " - 执行编译: make -j\$(nproc)"\n\
echo " - 清理编译: make clean"\n\
exec "$@"' > /entrypoint.sh && \
    chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
