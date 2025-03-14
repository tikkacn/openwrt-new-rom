#!/bin/bash
# build-openwrt.sh - 用于在Docker容器中执行OpenWrt增量编译

set -e

# 配置日志颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 日志函数
log() {
  echo -e "${BLUE}[$(date "+%Y-%m-%d %H:%M:%S")] $1${PLAIN}"
}

log_error() {
  echo -e "${RED}[$(date "+%Y-%m-%d %H:%M:%S")] ERROR: $1${PLAIN}"
}

log_success() {
  echo -e "${GREEN}[$(date "+%Y-%m-%d %H:%M:%S")] SUCCESS: $1${PLAIN}"
}

log_warning() {
  echo -e "${YELLOW}[$(date "+%Y-%m-%d %H:%M:%S")] WARNING: $1${PLAIN}"
}

# 初始化环境
init_env() {
  log "初始化环境..."
  
  # 确保目录存在
  mkdir -p $BUILD_STATE_DIR $CCACHE_DIR /workdir/firmware
  chmod -R 777 /workdir

  # 准备自定义脚本
  echo '#!/bin/bash' > $GITHUB_WORKSPACE/diy-part1.sh
  echo '# Feeds 已通过 FEEDS_CONF_URL 配置' >> $GITHUB_WORKSPACE/diy-part1.sh
  chmod +x $GITHUB_WORKSPACE/diy-part1.sh
  
  echo '#!/bin/bash' > $GITHUB_WORKSPACE/diy-part2.sh
  echo 'sed -i "s/OpenWrt /OpenWrt_AutoBuild /" package/lean/default-settings/files/zzz-default-settings' >> $GITHUB_WORKSPACE/diy-part2.sh
  chmod +x $GITHUB_WORKSPACE/diy-part2.sh

  # 检查配置文件是否存在
  if [ ! -f "$GITHUB_WORKSPACE/$CONFIG_FILE" ]; then
    log_warning "配置文件 $CONFIG_FILE 不存在，创建默认配置文件"
    echo "# 创建默认的最小化配置文件" > $GITHUB_WORKSPACE/$CONFIG_FILE
    echo "CONFIG_TARGET_x86=y" >> $GITHUB_WORKSPACE/$CONFIG_FILE
    echo "CONFIG_TARGET_x86_64=y" >> $GITHUB_WORKSPACE/$CONFIG_FILE
    echo "CONFIG_TARGET_x86_64_DEVICE_generic=y" >> $GITHUB_WORKSPACE/$CONFIG_FILE
    echo "CONFIG_PACKAGE_luci=y" >> $GITHUB_WORKSPACE/$CONFIG_FILE
  fi

  # 显示空间使用情况
  log "当前磁盘空间使用情况:"
  df -h
}

# 清理临时文件释放空间 - 修改版
cleanup_temp_files() {
  log "清理临时文件以释放空间..."
  
  # 安全清理 /tmp 目录中的一些特定类型文件，保留编译器需要的文件
  find /tmp -type f -name "*.log" -o -name "*.tmp" -o -name "*.cache" -delete 2>/dev/null || true
  
  # 对 /workdir/openwrt/tmp 采取更保守的清理策略
  # 不清理过新的文件(1分钟内)和编译器可能需要的关键文件(.s, .o等)
  find /workdir/openwrt/tmp -type f -mmin +1 -not -name "*.s" -not -name "*.o" -not -name "cc*" -delete 2>/dev/null || true
  
  # 清理不再需要的可能占用大量空间的下载缓存
  find /workdir/openwrt/dl -name "*.tar.gz" -mtime +5 -delete 2>/dev/null || true
  
  log "当前磁盘空间使用情况:"
  df -h
}

# 克隆或更新OpenWrt源码
clone_or_update_source() {
  log "处理OpenWrt源码..."
  
  # 检查OpenWrt文件夹是否存在
  if [ -d "/workdir/openwrt" ]; then
    log "OpenWrt源码目录已存在，检查更新..."
    cd /workdir/openwrt
    
    # 保存当前HEAD提交哈希
    CURRENT_COMMIT=$(git rev-parse HEAD)
    log "当前提交: $CURRENT_COMMIT"
    
    # 重置并更新源码
    git fetch --all
    git reset --hard origin/$REPO_BRANCH
    git clean -fd
    
    # 获取更新后的HEAD提交哈希
    NEW_COMMIT=$(git rev-parse HEAD)
    log "更新后提交: $NEW_COMMIT"
    
    # 检查是否有源码更新
    if [ "$CURRENT_COMMIT" != "$NEW_COMMIT" ] || [ "$FORCE_UPDATE" = "true" ]; then
      log_warning "源码已更新或强制更新被触发，需要重新编译"
      echo "source_changed=true" >> $GITHUB_ENV
      SOURCE_CHANGED=true
    else
      log "源码未变更"
      echo "source_changed=false" >> $GITHUB_ENV
      SOURCE_CHANGED=false
    fi
  else
    log "克隆新的OpenWrt源码..."
    git clone --depth 1 $REPO_URL -b $REPO_BRANCH /workdir/openwrt
    cd /workdir/openwrt
    log "首次克隆，需要完整编译"
    echo "source_changed=true" >> $GITHUB_ENV
    SOURCE_CHANGED=true
  fi
  
  # 确保所有脚本可执行
  find . -type f -name "*.sh" -exec chmod +x {} \;
  
  # 下载feeds配置
  curl -L -o feeds.conf.default "$FEEDS_CONF_URL" || log_warning "无法下载 feeds.conf.default，使用仓库默认配置"
  cat feeds.conf.default
  
  # 创建必要的目录结构
  mkdir -p bin/targets bin/packages build_dir staging_dir
}

# 检查Feeds变化
check_feeds() {
  log "检查Feeds变化..."
  cd /workdir/openwrt
  mkdir -p $BUILD_STATE_DIR
  
  # 更新feeds并获取最新状态
  ./scripts/feeds update -a
  
  # 计算feeds哈希值
  find feeds -type f -name "Makefile" -exec sha256sum {} \; | sort | sha256sum > $BUILD_STATE_DIR/feeds.sha256
  CURRENT_FEEDS_HASH=$(cat $BUILD_STATE_DIR/feeds.sha256 | awk '{print $1}')
  PREVIOUS_FEEDS_HASH=$(cat $BUILD_STATE_DIR/previous_feeds.sha256 2>/dev/null | awk '{print $1}' || echo "")
  
  log "当前 feeds 哈希: $CURRENT_FEEDS_HASH"
  log "之前 feeds 哈希: $PREVIOUS_FEEDS_HASH"
  
  if [ "$CURRENT_FEEDS_HASH" != "$PREVIOUS_FEEDS_HASH" ] || [ "$SOURCE_CHANGED" = "true" ]; then
    log_warning "Feeds 已变更或源码已更新，需要编译所有包"
    echo "feeds_changed=true" >> $GITHUB_ENV
    FEEDS_CHANGED=true
    # 强制编译所有包的文件标记
    touch $BUILD_STATE_DIR/rebuild_all_packages
  else
    log "Feeds 未变更，可以使用缓存包"
    echo "feeds_changed=false" >> $GITHUB_ENV
    FEEDS_CHANGED=false
    # 移除强制编译所有包的文件标记
    rm -f $BUILD_STATE_DIR/rebuild_all_packages
  fi
  
  # 安装feeds
  ./scripts/feeds install -a
  
  # 保存当前哈希值供下次比较
  cp $BUILD_STATE_DIR/feeds.sha256 $BUILD_STATE_DIR/previous_feeds.sha256
}

# 配置编译环境
configure_build() {
  log "配置编译环境..."
  cd /workdir/openwrt
  
  # 执行自定义脚本
  $GITHUB_WORKSPACE/$DIY_P1_SH
  
  # 复制自定义文件
  [ -e $GITHUB_WORKSPACE/files ] && cp -r $GITHUB_WORKSPACE/files ./files
  
  # 复制配置文件
  cp $GITHUB_WORKSPACE/$CONFIG_FILE ./.config
  cp .config .config.input
  
  # 执行第二个自定义脚本
  $GITHUB_WORKSPACE/$DIY_P2_SH
  
  # 添加自动配置
  echo "CONFIG_AUTOREMOVE=n" >> .config
  echo "CONFIG_AUTOREBUILD=n" >> .config
  
  # 生成最终配置
  make defconfig
  
  # 检查配置是否丢失软件包
  grep "^CONFIG_PACKAGE_.*=y" .config.input > packages_input.txt || true
  grep "^CONFIG_PACKAGE_.*=y" .config > packages_defconfig.txt || true
  comm -23 packages_input.txt packages_defconfig.txt > missing_packages.txt
  
  if [ -s missing_packages.txt ]; then
    log_warning "以下包在 defconfig 后缺失，将尝试恢复："
    cat missing_packages.txt
    cat missing_packages.txt >> .config
    
    while read -r line; do
      pkg=$(echo "$line" | sed 's/CONFIG_PACKAGE_\(.*\)=y/\1/')
      log "安装包: $pkg"
      ./scripts/feeds install "$pkg" || log_warning "无法安装 $pkg，可能不在 feeds 中"
    done < missing_packages.txt
    
    make defconfig
  else
    log "所有配置项均保留，无缺失"
  fi
  
  # 检查配置差异
  diff .config.input .config > config_diff.txt || echo "配置有差异"
  
  # 如果配置有变化，需要重新编译
  if [ -s config_diff.txt ]; then
    log "配置有变化，将只编译变化的包"
    # 找出新增和移除的包
    grep "^+CONFIG_PACKAGE_.*=y" config_diff.txt | sed 's/^+CONFIG_PACKAGE_\(.*\)=y/\1/' > added_packages.txt
    grep "^-CONFIG_PACKAGE_.*=y" config_diff.txt | sed 's/^-CONFIG_PACKAGE_\(.*\)=y/\1/' > removed_packages.txt
    
    if [ -s added_packages.txt ]; then
      log_warning "新增的包:"
      cat added_packages.txt
      cp added_packages.txt /workdir/added_packages.txt
    fi
    
    if [ -s removed_packages.txt ]; then
      log_warning "移除的包:"
      cat removed_packages.txt
      cp removed_packages.txt /workdir/removed_packages.txt
    fi
    
    echo "config_changed=true" >> $GITHUB_ENV
    CONFIG_CHANGED=true
  else
    log "配置无变化"
    echo "config_changed=false" >> $GITHUB_ENV
    CONFIG_CHANGED=false
  fi
}

# 下载软件包
download_packages() {
  log "下载软件包..."
  cd /workdir/openwrt
  make download -j8 || make download -j1 V=s
  
  # 配置CCACHE
  mkdir -p $CCACHE_DIR
  ccache -o cache_dir=$CCACHE_DIR
  ccache -o max_size=8G
  ccache -z
}

# 智能编译固件
compile_firmware() {
  cd /workdir/openwrt
  export CCACHE_DIR=$CCACHE_DIR
  export PATH="/usr/lib/ccache:$PATH"

  save_cache_info() {
    log "保存缓存状态信息..."
    mkdir -p $BUILD_STATE_DIR
    cp .config $BUILD_STATE_DIR/config.txt
    echo "$(date)" > $BUILD_STATE_DIR/last_build_time.txt
    echo "保存构建状态完成"
  }

  # 开始时间记录
  START_TIME=$(date +%s)
  log "开始编译时间: $(date)"
  
  # 修改：不再使用后台定期清理，改为在适当的时机手动清理
  # 创建一个函数用于在特定时间点安全清理
  safe_cleanup() {
    log "执行安全清理..."
    # 在编译暂停时手动清理，不会干扰进行中的任务
    cleanup_temp_files
  }
  
  # 决定编译策略
  if [ "$CLEAN_BUILD" = "true" ]; then
    # 用户请求完全重新编译
    log_warning "用户请求完全重新编译"
    make clean
    safe_cleanup  # 清理一次
    make -j$(nproc) V=s || make -j1 V=s
    BUILD_STATUS=$?
    
  elif [ "$FEEDS_CHANGED" = "true" ] || [ -f "$BUILD_STATE_DIR/rebuild_all_packages" ]; then
    # Feeds变更或源码变更，需要重新编译所有包
    log_warning "Feeds或源码已变更，重新编译所有包"
    make package/clean
    safe_cleanup  # 清理一次
    make -j$(nproc) V=s || make -j1 V=s
    BUILD_STATUS=$?
    
  elif [ "$CONFIG_CHANGED" = "true" ]; then
    # 配置有变化，只编译变化的包
    log_warning "配置有变化，进行智能增量编译"
    
    # 编译新增的包
    if [ -s added_packages.txt ]; then
      log "编译新增的包..."
      while read -r pkg; do
        log "编译包: $pkg"
        make package/$pkg/{clean,compile} -j$(nproc) V=s || make package/$pkg/{clean,compile} -j1 V=s
        # 每完成一个包的编译后安全清理
        safe_cleanup
      done < added_packages.txt
    fi
    
    # 移除已删除的包
    if [ -s removed_packages.txt ]; then
      log "清理移除的包..."
      while read -r pkg; do
        log "清理包: $pkg"
        make package/$pkg/clean V=s || true
      done < removed_packages.txt
      safe_cleanup
    fi
    
    # 构建固件
    log "生成最终固件..."
    make -j$(nproc) V=s || make -j1 V=s
    BUILD_STATUS=$?
    
  else
    # 无变化，仅重新生成固件
    log "配置和feeds都未变化，执行最小增量编译..."
    make -j$(nproc) V=s || make -j1 V=s
    BUILD_STATUS=$?
  fi
  
  # 结束时间记录
  END_TIME=$(date +%s)
  ELAPSED_TIME=$((END_TIME - START_TIME))
  
  log "结束编译时间: $(date)"
  log "总编译用时: $ELAPSED_TIME 秒 ($(date -d@$ELAPSED_TIME -u +%H:%M:%S))"
  
  # 保存缓存信息
  save_cache_info

  if [ $BUILD_STATUS -eq 0 ]; then
    log_success "编译成功"
    return 0
  else
    log_error "编译失败"
    return 1
  fi
}

# 整理固件文件
organize_firmware() {
  log "整理固件文件..."
  
  # 进入targets目录
  cd /workdir/openwrt/bin/targets/*/*
  
  # 清理旧的固件目录
  rm -rf firmware
  
  # 创建新的固件目录
  mkdir -p firmware
  
  # 查找固件文件
  FIRMWARE_FILES=$(find . -maxdepth 1 -name "*combined*" -or -name "*sysupgrade*")
  
  if [ -z "$FIRMWARE_FILES" ]; then
    log_warning "未找到固件文件，使用所有bin文件"
    FIRMWARE_FILES=$(find . -maxdepth 1 -name "*.bin")
  fi
  
  # 复制固件文件
  if [ -n "$FIRMWARE_FILES" ]; then
    echo "$FIRMWARE_FILES" | xargs -i cp {} ./firmware/
    log_success "成功复制固件文件"
  else
    log_warning "未找到任何固件文件，复制所有文件"
    cp -r * ./firmware/
  fi
  
  # 复制配置文件
  cp /workdir/openwrt/.config ./firmware/config.txt
  
  # 创建固件包
  zip -r firmware.zip firmware
  
  # 复制到输出目录
  rm -rf /workdir/firmware/*
  cp -r firmware/* /workdir/firmware/
  
  # 保存路径信息给GitHub Actions
  echo "DEVICE_NAME=_$(grep '^CONFIG_TARGET.*DEVICE.*=y' /workdir/openwrt/.config | sed -r 's/.*DEVICE_(.*)=y/\1/' | tr '\n' '_')" >> $GITHUB_ENV
  echo "FILE_DATE=_$(date +"%Y%m%d%H%M")" >> $GITHUB_ENV
  echo "BUILD_SUCCESS=true" >> $GITHUB_ENV
  echo "status=success" >> $GITHUB_OUTPUT
  
  # 创建版本信息
  echo "## 编译详情" > /workdir/build_info.txt
  
  if [ "$FEEDS_CHANGED" = "true" ] || [ "$SOURCE_CHANGED" = "true" ]; then
    echo "📢 此版本包含源码或feeds更新" >> /workdir/build_info.txt
  fi
  
  if [ "$CONFIG_CHANGED" = "true" ]; then
    echo "📢 此版本包含配置更改" >> /workdir/build_info.txt
    if [ -f /workdir/added_packages.txt ]; then
      echo "📦 新增软件包:" >> /workdir/build_info.txt
      cat /workdir/added_packages.txt | sed 's/^/- /' >> /workdir/build_info.txt
    fi
    if [ -f /workdir/removed_packages.txt ]; then
      echo "🗑️ 移除软件包:" >> /workdir/build_info.txt
      cat /workdir/removed_packages.txt | sed 's/^/- /' >> /workdir/build_info.txt
    fi
  fi
  
  echo "⏱️ 编译用时: $(date -d@$ELAPSED_TIME -u +%H:%M:%S)" >> /workdir/build_info.txt
  
  log_success "固件整理完成，可以在 /workdir/firmware 目录找到编译好的固件"
}

# SSH调试函数
start_ssh_debug() {
  if [ "$SSH_DEBUG" = "true" ]; then
    log "启动SSH调试会话..."
    apt-get update && apt-get install -y openssh-server
    mkdir -p /run/sshd
    echo 'root:password' | chpasswd
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    /usr/sbin/sshd -D &
    
    # 显示IP地址
    IP_ADDR=$(hostname -I | awk '{print $1}')
    log_warning "SSH服务已启动，可通过以下信息连接:"
    log_warning "主机: $IP_ADDR"
    log_warning "用户: root"
    log_warning "密码: password"
    log_warning "按Ctrl+C终止调试会话"
    
    # 等待用户操作
    sleep 3600
  fi
}

# 主函数
main() {
  # 设置变量
  SOURCE_CHANGED=false
  FEEDS_CHANGED=false
  CONFIG_CHANGED=false
  ELAPSED_TIME=0
  
  log "开始OpenWrt增量编译工作流..."
  
  # 初始化环境
  init_env
  
  # 处理SSH调试
  if [ "$SSH_DEBUG" = "true" ]; then
    start_ssh_debug
    exit 0
  fi
  
  # 执行构建步骤
  clone_or_update_source
  check_feeds
  configure_build
  download_packages
  
  # 执行编译
  if compile_firmware; then
    organize_firmware
  else
    log_error "编译失败，退出"
    echo "BUILD_SUCCESS=false" >> $GITHUB_ENV
    exit 1
  fi
  
  log_success "构建工作流完成!"
}

# 运行主函数
main
