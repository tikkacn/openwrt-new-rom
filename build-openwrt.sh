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

# 克隆或更新OpenWrt源码 - 修改后的版本
clone_or_update_source() {
  log "处理OpenWrt源码..."
  
  # 检查是否从缓存恢复的源码，且确保源码完整
  if [ -f "$BUILD_STATE_DIR/source_from_cache" ] && [ -d "/workdir/openwrt" ] && [ -d "/workdir/openwrt/scripts" ] && [ -x "/workdir/openwrt/scripts/feeds" ]; then
    log "检测到从缓存恢复的有效源码，跳过源码更新检查"
    echo "source_changed=false" >> $GITHUB_ENV
    SOURCE_CHANGED=false
    return 0
  fi
  
  # 如果缓存标记存在但源码不完整，移除标记
  if [ -f "$BUILD_STATE_DIR/source_from_cache" ]; then
    log_warning "缓存标记存在但源码不完整，将重新克隆源码"
    rm -f "$BUILD_STATE_DIR/source_from_cache"
  fi
  
  # 检查OpenWrt文件夹是否存在并且是有效的git仓库
  if [ -d "/workdir/openwrt" ] && [ -d "/workdir/openwrt/.git" ]; then
    log "OpenWrt源码目录已存在，检查更新..."
    cd /workdir/openwrt
    
    # 检查是否是有效的git仓库
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      # 保存当前HEAD提交哈希
      CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
      log "当前提交: $CURRENT_COMMIT"
      
      # 如果无法获取哈希或是首次运行，但源码目录已存在
      if [ "$CURRENT_COMMIT" = "unknown" ] && [ -f ".config" ]; then
        log "无法获取当前提交哈希，但源码目录已存在，假定未更改"
        echo "source_changed=false" >> $GITHUB_ENV
        SOURCE_CHANGED=false
        return 0
      fi
      
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
      log_warning "现有目录不是有效的git仓库，重新克隆"
      rm -rf /workdir/openwrt
      git clone --depth 1 $REPO_URL -b $REPO_BRANCH /workdir/openwrt
      cd /workdir/openwrt
      log "重新克隆，需要完整编译"
      echo "source_changed=true" >> $GITHUB_ENV
      SOURCE_CHANGED=true
    fi
  else
    log "克隆新的OpenWrt源码..."
    rm -rf /workdir/openwrt  # 确保目录干净
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
  
  # 修改判断逻辑，分离源码变更和feeds变更的影响
  if [ "$CURRENT_FEEDS_HASH" != "$PREVIOUS_FEEDS_HASH" ]; then
    # feeds真正发生变化
    log_warning "Feeds 已变更，需要编译所有包"
    echo "feeds_changed=true" >> $GITHUB_ENV
    FEEDS_CHANGED=true
    # 强制编译所有包的文件标记
    touch $BUILD_STATE_DIR/rebuild_all_packages
  elif [ "$SOURCE_CHANGED" = "true" ] && [ "$FORCE_UPDATE" = "true" ]; then
    # 只有在强制更新标志为true时才因源码变更而强制重新编译
    log_warning "源码已更新且强制更新被触发，需要编译所有包"
    echo "feeds_changed=true" >> $GITHUB_ENV
    FEEDS_CHANGED=true
    # 强制编译所有包的文件标记
    touch $BUILD_STATE_DIR/rebuild_all_packages
  else
    # feeds没有变更，或者源码变更但非强制更新
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
  ccache -o max_size=5G  # 限制CCACHE大小为5G，防止超出GitHub Actions缓存限制
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

# 准备缓存权限
prepare_cache() {
  log "准备缓存目录权限..."
  
  # 修复root-x86目录权限，这是缓存问题的主要来源
  if [ -d "/workdir/openwrt/build_dir/target-x86_64_musl/root-x86" ]; then
    chmod -R 755 /workdir/openwrt/build_dir/target-x86_64_musl/root-x86 2>/dev/null || true
    find /workdir/openwrt/build_dir/target-x86_64_musl/root-x86 -type f -exec chmod 644 {} \; 2>/dev/null || true
  fi
  
  # 修复所有构建目录的权限
  find /workdir/openwrt/build_dir -type d -exec chmod 755 {} \; 2>/dev/null || true
  
  # 特别处理关键配置文件的权限 - 日志中显示这些是主要问题
  find /workdir/openwrt/build_dir -name "*.conf" -o -name "*.txt" -o -name "*.so" -o -name "*.secrets" -o -name "shadow" -o -name "*.user" -exec chmod 644 {} \; 2>/dev/null || true
  
  # 处理thinlto-cache目录和其他特殊目录
  find /workdir/openwrt/build_dir -path "*/thinlto-cache*" -exec chmod -R 755 {} \; 2>/dev/null || true
  find /workdir/openwrt/build_dir -path "*/ipkg-*" -exec chmod -R 755 {} \; 2>/dev/null || true
  find /workdir/openwrt/build_dir -path "*/.pkgdir*" -exec chmod -R 755 {} \; 2>/dev/null || true
  
  # 修正 /etc 目录权限，这是常见的权限问题区域
  find /workdir/openwrt/build_dir -path "*/etc*" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find /workdir/openwrt/build_dir -path "*/etc*" -type f -exec chmod 644 {} \; 2>/dev/null || true
  
  # 优化缓存大小，移除不需要的大文件
  log "优化缓存大小..."
  
  # 清理重复或旧的下载文件
  find /workdir/openwrt/dl -type f -name "*.tar.*" -mtime +10 -delete 2>/dev/null || true
  
  # 清理不需要缓存的编译中间文件
  find /workdir/openwrt/build_dir -name "*.o" -delete 2>/dev/null || true
  find /workdir/openwrt/build_dir -name "*.so" -delete 2>/dev/null || true
  find /workdir/openwrt/build_dir -name "*.a" -delete 2>/dev/null || true
  
  # 清理缓存目录中的临时文件
  find /workdir/openwrt/build_dir -name "*.tmp" -delete 2>/dev/null || true
  find /workdir/openwrt/build_dir -name "*.log" -delete 2>/dev/null || true
  
  log_success "缓存目录权限已修复并优化缓存大小"
}

# 修复所有缓存文件的权限问题
fix_all_permissions() {
  log "修复所有缓存文件权限..."
  
  # 使用sudo确保有足够权限
  sudo find /workdir/openwrt/build_dir -type d -exec chmod 755 {} \; 2>/dev/null || true
  sudo find /workdir/openwrt/build_dir -type f -exec chmod 644 {} \; 2>/dev/null || true
  
  # 处理可执行文件，保留可执行权限
  sudo find /workdir/openwrt/build_dir -type f -name "*.sh" -exec chmod 755 {} \; 2>/dev/null || true
  sudo find /workdir/openwrt/build_dir -path "*/bin/*" -type f -exec chmod 755 {} \; 2>/dev/null || true
  
  # 处理特殊的锁文件
  sudo find /workdir/openwrt/build_dir -name "*.lock" -delete 2>/dev/null || true
  
  # 更改所有文件的所有者
  sudo chown -R 1000:1000 /workdir/openwrt 2>/dev/null || true
  
  # 修复cargo目录权限
  if [ -d "/workdir/openwrt/dl/cargo" ]; then
    sudo chmod -R 755 /workdir/openwrt/dl/cargo
    sudo find /workdir/openwrt/dl/cargo -type f -exec chmod 644 {} \; 2>/dev/null || true
  fi
  
  log_success "所有文件权限已修复"
}

# 压缩缓存文件以节省存储空间
compress_cache_for_storage() {
  log "压缩缓存文件以节省存储空间..."
  
  mkdir -p /workdir/cached_archives
  
  # 压缩bin目录
  log "压缩bin目录..."
  tar -czf /workdir/cached_archives/bin.tar.gz -C /workdir/openwrt bin || true
  
  # 压缩staging_dir目录
  log "压缩staging_dir目录..."
  tar -czf /workdir/cached_archives/staging_dir.tar.gz -C /workdir/openwrt staging_dir || true
  
  # 分段压缩build_dir目录(分成多个较小的文件)
  log "分段压缩build_dir目录..."
  
  # 将build_dir分成几个主要部分
  if [ -d "/workdir/openwrt/build_dir/target-x86_64_musl" ]; then
    log "压缩目标平台编译缓存..."
    tar -czf /workdir/cached_archives/build_dir_target.tar.gz -C /workdir/openwrt build_dir/target-* || true
  fi
  
  if [ -d "/workdir/openwrt/build_dir/host" ]; then
    log "压缩主机工具编译缓存..."
    tar -czf /workdir/cached_archives/build_dir_host.tar.gz -C /workdir/openwrt build_dir/host || true
  fi
  
  # 更通用的工具链检测和压缩 - 改进后
  log "查找工具链目录..."
  # 使用find命令查找任何名称包含toolchain的目录
  TOOLCHAIN_DIRS=$(find /workdir/openwrt/build_dir -type d -name "*toolchain*" | grep -v host 2>/dev/null || true)
  if [ -n "$TOOLCHAIN_DIRS" ]; then
    log "发现工具链目录: $TOOLCHAIN_DIRS"
    log "压缩工具链编译缓存..."
    
    # 创建一个临时目录列表文件
    TEMP_LIST=$(mktemp)
    echo "$TOOLCHAIN_DIRS" | sed 's|/workdir/openwrt/||g' > $TEMP_LIST
    
    # 使用文件列表进行打包
    tar -czf /workdir/cached_archives/build_dir_toolchain.tar.gz -C /workdir/openwrt -T $TEMP_LIST || true
    
    # 检查是否成功创建文件
    if [ -f "/workdir/cached_archives/build_dir_toolchain.tar.gz" ]; then
      log_success "工具链缓存文件创建成功"
    else
      log_warning "工具链缓存文件创建失败"
    fi
    
    # 清理临时文件
    rm -f $TEMP_LIST
  else
    log_warning "未找到工具链目录，跳过工具链缓存"
  fi
  
  # 压缩源码和feeds目录 - 新增
  if [ -d "/workdir/openwrt" ]; then
    log "压缩源码和feeds目录..."
    # 排除一些不必要的大文件和Git历史记录，以及已经单独缓存的目录
    tar --exclude='.git' --exclude='dl' --exclude='bin' --exclude='build_dir' --exclude='staging_dir' \
        -czf /workdir/cached_archives/source_and_feeds.tar.gz -C /workdir openwrt || true
  fi
  
  # 确保归档文件对所有用户可读
  chmod -R 777 /workdir/cached_archives
  
  log "缓存压缩完成，存储在 /workdir/cached_archives/"
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
    prepare_cache
    fix_all_permissions
    compress_cache_for_storage  # 添加压缩缓存步骤
  else
    log_error "编译失败，退出"
    echo "BUILD_SUCCESS=false" >> $GITHUB_ENV
    exit 1
  fi
  
  log_success "构建工作流完成!"
}

# 运行主函数
main
