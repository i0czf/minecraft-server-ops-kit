# 便携服务端图形控制面板（WPF）
# 维护注意：
# - 本文件含中文，必须保存为 UTF-8 带 BOM（无 BOM 时 Windows PowerShell 5 按 ANSI 解析，满屏语法错误）。
# - 面板只做「状态展示 + 调度既有一键入口 + RCON 快捷控制台」，不重写任何发布/同步/监控逻辑；
#   业务改动请继续改对应的一键 bat 和 tools 脚本，面板会自动跟随。
# - 入口是根目录「一键便携-控制面板.bat」，以 -STA 同步、可见窗口启动本脚本；GUI 就绪后本脚本自行最小化控制台。
#   禁止改回 start + -WindowStyle Hidden 启动：该组合会被杀软按木马下载器特征删除 bat（2026-07-06 火绒实锤）。

param()

$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Add-Type -AssemblyName System.Windows.Forms # 只用于「选择主客户端」的文件夹选择器

    # 修复部分机器首帧合成错乱（窗口半透明、控件散落，最大化一下才恢复）：
    # 是 WPF 硬件渲染与显卡驱动的兼容问题，强制软件渲染即可根治；面板很轻，性能无感。
    try { [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly } catch { }

    $Root = Split-Path -Parent $PSScriptRoot
    $ToolsDir = $PSScriptRoot

    # 控制台窗口宿主：不隐藏（杀软友好 + 崩溃时还能看到报错），GUI 就绪后最小化到任务栏。
    try { $Host.UI.RawUI.WindowTitle = '便携控制面板宿主（关闭此窗口会退出面板）' } catch { }
    $ConsoleUtil = $null
    try {
        $ConsoleUtil = Add-Type -Namespace PanelNative -Name ConsoleUtil -PassThru -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    } catch { $ConsoleUtil = $null }
    function Hide-HostConsole {
        if (-not $ConsoleUtil) { return }
        try {
            $h = $ConsoleUtil::GetConsoleWindow()
            if ($h -ne [IntPtr]::Zero) { [void]$ConsoleUtil::ShowWindow($h, 6) } # 6 = SW_MINIMIZE
        } catch { }
    }

    # ---------- 主题 ----------
    # 所有颜色都通过 DynamicResource 引用（键名 Th*），换主题 = 整体替换 window.Resources 里的画刷。
    # 代码里动态创建的控件一律用 SetResourceReference 绑定，换肤时会自动跟随，不要直接赋 Brush。
    function New-Brush([string]$Hex) {
        $c = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
        $b = New-Object System.Windows.Media.SolidColorBrush($c)
        $b.Freeze()
        return $b
    }
    $Themes = @(
        @{ Name = '暗夜'; C = @{
            ThWindowBg='#16171B'; ThCardBg='#1F2127'; ThCardBorder='#2E313A'
            ThTextMain='#E8EAF0'; ThTextDim='#9AA0AE'; ThInputBg='#14151A'
            ThBtnBase='#262933'; ThBtnChip='#2A2E38'; ThBtnLink='#22252D'; ThBtnFg='#E8EAF0'
            ThAccent='#2E6B4F'; ThDanger='#6B3138'; ThAccentFg='#F2F5F3'; ThSelection='#2E6B4F'
            ThGood='#4FC08D'; ThBad='#E06C75'; ThWarn='#E5C07B'; ThOff='#565B68' } }
        @{ Name = '白昼'; C = @{
            ThWindowBg='#F1F2F6'; ThCardBg='#FFFFFF'; ThCardBorder='#DFE2EA'
            ThTextMain='#262A33'; ThTextDim='#6E7583'; ThInputBg='#F6F7FA'
            ThBtnBase='#E7EAF1'; ThBtnChip='#ECEEF4'; ThBtnLink='#F0F2F6'; ThBtnFg='#262A33'
            ThAccent='#2F8F63'; ThDanger='#C25450'; ThAccentFg='#FFFFFF'; ThSelection='#9FD4BC'
            ThGood='#2FA46F'; ThBad='#D64545'; ThWarn='#B98A00'; ThOff='#B4BAC6' } }
        @{ Name = '深海'; C = @{
            ThWindowBg='#0D1520'; ThCardBg='#152232'; ThCardBorder='#23374D'
            ThTextMain='#DCE7F3'; ThTextDim='#8CA3BB'; ThInputBg='#0B121C'
            ThBtnBase='#1D2F44'; ThBtnChip='#21354C'; ThBtnLink='#182838'; ThBtnFg='#DCE7F3'
            ThAccent='#2B6FA3'; ThDanger='#75394B'; ThAccentFg='#F0F6FC'; ThSelection='#2B6FA3'
            ThGood='#43C6A5'; ThBad='#E4718A'; ThWarn='#DFB35F'; ThOff='#47607A' } }
        @{ Name = '翡翠'; C = @{
            ThWindowBg='#0F1714'; ThCardBg='#17231E'; ThCardBorder='#26392F'
            ThTextMain='#E1EFE7'; ThTextDim='#8FA89A'; ThInputBg='#0C1310'
            ThBtnBase='#203129'; ThBtnChip='#24382E'; ThBtnLink='#1B2A23'; ThBtnFg='#E1EFE7'
            ThAccent='#2E7D5A'; ThDanger='#6E3540'; ThAccentFg='#F0F7F3'; ThSelection='#2E7D5A'
            ThGood='#52C795'; ThBad='#E06C75'; ThWarn='#D8B35E'; ThOff='#4D6156' } }
        @{ Name = '樱花'; C = @{
            ThWindowBg='#FAF1F4'; ThCardBg='#FFFFFF'; ThCardBorder='#EFDAE1'
            ThTextMain='#3B2B32'; ThTextDim='#997987'; ThInputBg='#FBF6F8'
            ThBtnBase='#F2E2E8'; ThBtnChip='#F4E7EC'; ThBtnLink='#F6EDF1'; ThBtnFg='#3B2B32'
            ThAccent='#C4557C'; ThDanger='#B0413E'; ThAccentFg='#FFFFFF'; ThSelection='#EBB8CB'
            ThGood='#2FA46F'; ThBad='#D64545'; ThWarn='#B98A00'; ThOff='#C9B2BC' } }
    )

    # ---------- XAML ----------
    $xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="服务器运维控制面板" Width="1160" Height="760" MinWidth="900" MinHeight="560"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource ThWindowBg}"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display"
        FontFamily="Microsoft YaHei UI" FontSize="13">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource ThCardBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource ThCardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="16,13,16,15"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource ThTextMain}"/>
      <Setter Property="FontSize" Value="14.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource ThTextDim}"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="BaseButton" TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource ThBtnBase}"/>
      <Setter Property="Foreground" Value="{DynamicResource ThBtnFg}"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.82"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.65"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Background" Value="{DynamicResource ThAccent}"/>
      <Setter Property="Foreground" Value="{DynamicResource ThAccentFg}"/>
    </Style>
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Background" Value="{DynamicResource ThDanger}"/>
      <Setter Property="Foreground" Value="{DynamicResource ThAccentFg}"/>
    </Style>
    <Style x:Key="ChipButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Background" Value="{DynamicResource ThBtnChip}"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
    </Style>
    <Style x:Key="LinkButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Padding" Value="10,5"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Background" Value="{DynamicResource ThBtnLink}"/>
      <Setter Property="Foreground" Value="{DynamicResource ThTextDim}"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource ThInputBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource ThTextMain}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource ThCardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="CaretBrush" Value="{DynamicResource ThTextMain}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource ThSelection}"/>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
    </Style>
  </Window.Resources>

  <Grid Margin="16,14,16,10">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="330"/>
      <ColumnDefinition Width="16"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- ============ 左栏：状态 ============ -->
    <ScrollViewer Grid.Column="0" Grid.Row="0" VerticalScrollBarVisibility="Auto">
      <StackPanel>
        <StackPanel Orientation="Horizontal" Margin="2,0,0,10">
          <TextBlock Text="⛏" FontSize="22" Margin="0,0,8,0" Foreground="{DynamicResource ThTextMain}"/>
          <StackPanel>
            <TextBlock Text="服务器运维控制面板" Foreground="{DynamicResource ThTextMain}" FontSize="17" FontWeight="Bold"/>
            <TextBlock x:Name="txtRootPath" Text="" Style="{StaticResource Hint}" Margin="0,2,0,0"/>
          </StackPanel>
        </StackPanel>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <Grid Margin="0,0,0,6">
              <TextBlock Text="📡 运行状态" Style="{StaticResource CardTitle}" Margin="0"/>
              <Button x:Name="btnRefresh" Content="刷新" Style="{StaticResource ChipButton}"
                      HorizontalAlignment="Right" Margin="0" Padding="10,2"/>
            </Grid>
            <StackPanel x:Name="statusList"/>
            <TextBlock x:Name="txtLastRefresh" Style="{StaticResource Hint}" Margin="0,8,0,0"/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <Grid Margin="0,0,0,4">
              <TextBlock Text="📊 性能监控" Style="{StaticResource CardTitle}" Margin="0"/>
              <TextBlock Text="每 5 秒刷新" Style="{StaticResource Hint}"
                         HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <UniformGrid x:Name="gaugePanel" Columns="4" Margin="0,2,0,10"/>
            <Border Background="{DynamicResource ThInputBg}" CornerRadius="8" Padding="10,8,10,7" Margin="0,0,0,10">
              <StackPanel>
                <Canvas x:Name="sparkCanvas" Height="46" ClipToBounds="True"/>
                <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                  <Ellipse Width="7" Height="7" Fill="{DynamicResource ThGood}" VerticalAlignment="Center"/>
                  <TextBlock Text="服务端 CPU" Style="{StaticResource Hint}" Margin="4,0,12,0"/>
                  <Ellipse Width="7" Height="7" Fill="{DynamicResource ThWarn}" VerticalAlignment="Center"/>
                  <TextBlock Text="系统内存" Style="{StaticResource Hint}" Margin="4,0,12,0"/>
                  <TextBlock Text="· 最近 5 分钟" Style="{StaticResource Hint}"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <StackPanel x:Name="perfList"/>
            <TextBlock Style="{StaticResource Hint}" Margin="0,6,0,0"
                       Text="世界/备份占用为后台扫描，约每分钟更新，不影响面板流畅。"/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="📦 整合包信息" Style="{StaticResource CardTitle}"/>
            <StackPanel x:Name="packInfoList"/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="📁 日志与目录" Style="{StaticResource CardTitle}"/>
            <WrapPanel>
              <Button x:Name="btnLogServer" Content="服务端日志" Style="{StaticResource LinkButton}"/>
              <Button x:Name="btnLogWrapper" Content="启动器日志" Style="{StaticResource LinkButton}"/>
              <Button x:Name="btnLogDiscord" Content="监控日志" Style="{StaticResource LinkButton}"
                      ToolTip="Discord/QQ 通知共用的日志监控引擎日志（discord-watch.log）"/>
              <Button x:Name="btnLogQQ" Content="QQ 桥接日志" Style="{StaticResource LinkButton}"/>
              <Button x:Name="btnOpenServerMods" Content="服务端 mods" Style="{StaticResource LinkButton}"/>
              <Button x:Name="btnOpenClientMods" Content="主客户端 mods" Style="{StaticResource LinkButton}"/>
              <Button x:Name="btnOpenClientRoot" Content="主客户端根目录" Style="{StaticResource LinkButton}"/>
              <Button x:Name="btnPickClient" Content="选择主客户端…" Style="{StaticResource LinkButton}"
                      ToolTip="用文件夹选择器指定主分发客户端目录，可以在服务端目录外"/>
              <Button x:Name="btnOpenRoot" Content="打开根目录" Style="{StaticResource LinkButton}"/>
              <Button x:Name="btnOpenDist" Content="打开 dist" Style="{StaticResource LinkButton}"/>
              <Button x:Name="btnOpenPackJson" Content="pack 配置" Style="{StaticResource LinkButton}"/>
              <Button x:Name="btnOpenOpsJson" Content="ops 配置" Style="{StaticResource LinkButton}"/>
            </WrapPanel>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="🎛 常用设置" Style="{StaticResource CardTitle}"/>
            <WrapPanel>
              <Button x:Name="chipOnline" Content="正版验证：…" Style="{StaticResource ChipButton}"/>
              <Button x:Name="chipWhitelist" Content="白名单：…" Style="{StaticResource ChipButton}"/>
              <Button x:Name="chipPvp" Content="PVP：…" Style="{StaticResource ChipButton}"/>
              <Button x:Name="chipDifficulty" Content="难度：…" Style="{StaticResource ChipButton}"/>
            </WrapPanel>
            <TextBlock Style="{StaticResource Hint}" Margin="0,4,0,0"
                       Text="点击即切换并写入 server.properties（写入前自动备份到 backups\panel-config），重启 Minecraft 服务端后生效。"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>

    <!-- ============ 右栏：操作 + RCON ============ -->
    <Grid Grid.Column="2" Grid.Row="0">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
        <StackPanel>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <Grid Margin="0,0,0,6">
                <TextBlock Text="🚀 上手路线" Style="{StaticResource CardTitle}" Margin="0"/>
                <TextBlock x:Name="txtGuideHint" Text="" Style="{StaticResource Hint}"
                           HorizontalAlignment="Right" VerticalAlignment="Center" MaxWidth="520" TextAlignment="Right"/>
              </Grid>
              <WrapPanel x:Name="guideSteps"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="⚙ ① 配置" Style="{StaticResource CardTitle}"/>
              <TextBlock Text="第一次迁移或改完配置后从这里开始。所有操作会在新的控制台窗口里进行。"
                         Style="{StaticResource Hint}" Margin="0,0,0,8"/>
              <WrapPanel>
                <Button x:Name="btnWizard" Content="初始化配置向导" Style="{StaticResource AccentButton}"/>
                <Button x:Name="btnQQSetup" Content="配置 QQ 机器人" Style="{StaticResource BaseButton}"/>
                <Button x:Name="btnRcon" Content="启用 RCON 反控" Style="{StaticResource BaseButton}"/>
                <Button x:Name="btnRconOff" Content="关闭 RCON" Style="{StaticResource BaseButton}"
                        ToolTip="把 enable-rcon 设为 false（端口和密码保留，下次可一键重开）；同机多服只开一个时无需关闭，只有同时运行才会端口冲突。重启 Minecraft 服务端后生效"/>
                <Button x:Name="btnPickClientCfg" Content="选择分发客户端目录" Style="{StaticResource BaseButton}"
                        ToolTip="用文件夹选择器指定主分发客户端目录，可以在服务端目录外的任意位置"/>
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="🖥 ② 服务端运行" Style="{StaticResource CardTitle}"/>
              <TextBlock Text="启动服务端会连带拉起 Discord/QQ/备份监控，并启用 10 秒自动重启。重启/停止均先安全保存世界（走 RCON stop）。"
                         Style="{StaticResource Hint}" Margin="0,0,0,8"/>
              <WrapPanel>
                <Button x:Name="btnStartServer" Content="启动服务端" Style="{StaticResource AccentButton}"/>
                <Button x:Name="btnRestartServer" Content="重启服务端" Style="{StaticResource BaseButton}"
                        ToolTip="通过 RCON 安全 stop（世界先保存），看门狗 10 秒后自动拉起新进程"/>
                <Button x:Name="btnStopServer" Content="停止服务端" Style="{StaticResource DangerButton}"
                        ToolTip="写入 maintenance.stop 停服标记并安全 stop，不会自动重启；下次点「启动服务端」自动清除标记"/>
                <Button x:Name="btnUpdateServer" Content="开启更新服务" Style="{StaticResource BaseButton}"/>
                <Button x:Name="btnHealthCheck" Content="健康体检" Style="{StaticResource AccentButton}"
                        ToolTip="只读体检：版本/Java/模组/配置/端口/备份/日志指纹，输出红黄绿评分；新窗口运行，可加诊断包"/>
                <Button x:Name="btnHealthPack" Content="生成诊断包" Style="{StaticResource BaseButton}"
                        ToolTip="体检并生成脱敏诊断包（过滤密钥/Token/玩家IP），输出到 tmp\health-check\"/>
                <Button x:Name="btnWeeklyReport" Content="运行报告" Style="{StaticResource BaseButton}"
                        ToolTip="只读汇总黑匣子/备份/崩溃/指纹/审计（默认近 7 天），输出到 tmp\weekly-report\"/>
                <Button x:Name="btnIncidentPostmortem" Content="事故复盘" Style="{StaticResource BaseButton}"
                        ToolTip="只读关联时间线、性能、卡顿、指纹、审计、崩溃与备份证据（默认近 24 小时），输出到 tmp\incident-postmortem\"/>
                <Button x:Name="btnBlueMapTimeMachine" Content="BlueMap 时光机" Style="{StaticResource BaseButton}"
                        ToolTip="只读生成 BlueMap 地图元数据快照与前后差异；默认不复制约 8.9GB 瓦片，可用脚本参数 deep 做瓦片统计"/>
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="🛰 ③ 运维监控" Style="{StaticResource CardTitle}"/>
              <TextBlock Text="改完配置或脚本后点「重启运维监控」一键先停后起全部运维，无需重启 Minecraft 服务端。"
                         Style="{StaticResource Hint}" Margin="0,0,0,8"/>
              <WrapPanel>
                <Button x:Name="btnOpsRestart" Content="重启运维监控" Style="{StaticResource AccentButton}"/>
                <Button x:Name="btnOpsStart" Content="启动所有运维" Style="{StaticResource BaseButton}"/>
                <Button x:Name="btnOpsStop" Content="停止所有运维" Style="{StaticResource DangerButton}"/>
                <Button x:Name="btnQQStart" Content="启动 QQ 机器人" Style="{StaticResource BaseButton}"/>
                <Button x:Name="btnQQTest" Content="测试 QQ 机器人" Style="{StaticResource BaseButton}"/>
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="🚚 ④ 发布与拉新" Style="{StaticResource CardTitle}"/>
              <TextBlock Text="改完主分发客户端后：日常增量点「仅发布更新」（不含枪皮等大件）；拉新玩家点「生成规范导入包」产出 mrpack + PCL 压缩包。「打包完整包」另出一个自带枪皮/光影/材质/资源包的完整客户端 zip，拉新一次装好——枪皮等大件走这里，不进日常增量更新。"
                         Style="{StaticResource Hint}" Margin="0,0,0,8"/>
              <WrapPanel>
                <Button x:Name="btnPublish" Content="仅发布更新" Style="{StaticResource AccentButton}"/>
                <Button x:Name="btnImportPack" Content="生成规范导入包" Style="{StaticResource BaseButton}"/>
                <Button x:Name="btnFullPack" Content="打包完整包" Style="{StaticResource BaseButton}"/>
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="🔄 ⑤ 工具包更新" Style="{StaticResource CardTitle}"/>
              <TextBlock Text="「检查更新」比对最新版工具包并展示更新日志，可一键更新并重启面板；本服 pack/ops 配置永不覆盖。生成按钮仅作者目录可见：公开包不带密钥、精简包再去 LLBot（便于传播）、私用包含配置仅自用。"
                         Style="{StaticResource Hint}" Margin="0,0,0,8"/>
              <WrapPanel>
                <Button x:Name="btnKitUpdate" Content="检查更新" Style="{StaticResource AccentButton}"
                        ToolTip="按 tools\toolkit-update-source.txt 的更新源（本地 zip 或作者更新服务器）比对版本，弹窗展示更新日志，可一键更新并重启面板"/>
                <Button x:Name="btnKitPublic" Content="生成公开工具包" Style="{StaticResource BaseButton}"/>
                <Button x:Name="btnKitLite" Content="生成精简工具包" Style="{StaticResource BaseButton}"
                        ToolTip="公开包的精简变体：不含 LLBot 程序本体，zip 从约 77MB 缩到几百 KB，适合网络分享"/>
                <Button x:Name="btnKitPrivate" Content="生成私用工具包" Style="{StaticResource BaseButton}"/>
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <Grid Margin="0,0,0,6">
                <TextBlock Text="💾 备份管理" Style="{StaticResource CardTitle}" Margin="0"/>
                <TextBlock x:Name="txtBackupStats" Text="" Style="{StaticResource Hint}"
                           HorizontalAlignment="Right" VerticalAlignment="Center"/>
              </Grid>
              <WrapPanel Margin="0,0,0,2">
                <ComboBox x:Name="cmbBackupDate" MinWidth="132" FontSize="12" Margin="0,0,8,6"
                          VerticalContentAlignment="Center"/>
                <Button x:Name="btnBackupNow" Content="立即备份" Style="{StaticResource ChipButton}"
                        ToolTip="在新窗口执行一次世界备份（先走 RCON 安全存档；服务端没开也能备份）"/>
                <Button x:Name="btnBackupDelete" Content="删除选中" Style="{StaticResource ChipButton}"
                        ToolTip="删除列表里选中的备份 zip（会先弹窗确认，删除后无法恢复）"/>
                <Button x:Name="btnBackupOpen" Content="打开备份目录" Style="{StaticResource ChipButton}"/>
                <Button x:Name="btnBackupRefresh" Content="刷新列表" Style="{StaticResource ChipButton}"/>
              </WrapPanel>
              <ListBox x:Name="lstBackups" Height="150" SelectionMode="Extended"
                       Background="{DynamicResource ThInputBg}" Foreground="{DynamicResource ThTextMain}"
                       BorderBrush="{DynamicResource ThCardBorder}" BorderThickness="1"
                       FontFamily="Consolas, Microsoft YaHei UI" FontSize="12"
                       ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
              <TextBlock Style="{StaticResource Hint}" Margin="0,6,0,0"
                         Text="备份由「备份调度」自动产生，也可点「立即备份」手动触发。列表可按日期筛选、Ctrl/Shift 多选；双击一条备份可在资源管理器中定位文件。"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="⬇ 服务端下载与安装" Style="{StaticResource CardTitle}"/>
              <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,8"
                         Text="选择任意目录，自选 Minecraft 版本与加载器（原版 / Forge / NeoForge / Fabric），一键下载部署全新服务端：支持官方源与 BMCLAPI 国内镜像，Java 自动匹配，向导里确认 EULA。部署到新目录后把工具包复制过去，就能用面板管理新服。"/>
              <WrapPanel>
                <Button x:Name="btnInstallPick" Content="选择目录并安装…" Style="{StaticResource AccentButton}"/>
                <Button x:Name="btnInstallHere" Content="安装到当前目录" Style="{StaticResource BaseButton}"
                        ToolTip="在本服务端目录重装/升级核心（world、mods 等数据不会被删除，同名核心文件会被覆盖，向导里还会再确认一次）"/>
              </WrapPanel>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- RCON 控制台 -->
      <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,0,0,0">
        <StackPanel>
          <Grid Margin="0,0,0,8">
            <TextBlock Text="⌨ RCON 快捷控制台" Style="{StaticResource CardTitle}" Margin="0"/>
            <TextBlock x:Name="txtRconState" Text="" Style="{StaticResource Hint}"
                       HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
          <WrapPanel Margin="0,0,0,4">
            <Button x:Name="chipList" Content="在线玩家" Style="{StaticResource ChipButton}"/>
            <Button x:Name="chipTps" Content="TPS" Style="{StaticResource ChipButton}"/>
            <Button x:Name="chipDay" Content="设为白天" Style="{StaticResource ChipButton}"/>
            <Button x:Name="chipWeather" Content="放晴" Style="{StaticResource ChipButton}"/>
            <Button x:Name="chipSave" Content="立即存档" Style="{StaticResource ChipButton}"/>
          </WrapPanel>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="8"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="txtRconInput" Grid.Column="0" FontFamily="Consolas, Microsoft YaHei UI"/>
            <Button x:Name="btnRconSend" Grid.Column="2" Content="发送" Style="{StaticResource AccentButton}"
                    Margin="0" Padding="20,6"/>
          </Grid>
          <TextBox x:Name="txtOutput" Height="120" Margin="0,8,0,0" IsReadOnly="True"
                   FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"
                   VerticalScrollBarVisibility="Auto" AcceptsReturn="True"/>
        </StackPanel>
      </Border>
    </Grid>

    <!-- ============ 底栏 ============ -->
    <Grid Grid.Column="0" Grid.ColumnSpan="3" Grid.Row="1" Margin="2,8,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Style="{StaticResource Hint}" VerticalAlignment="Center"
                 Text="面板只负责调度与查看：所有实际操作仍由根目录一键脚本完成，关闭面板不影响任何已启动的进程。"/>
      <Button x:Name="btnTheme" Grid.Column="1" Content="主题" Style="{StaticResource ChipButton}"
              Margin="12,0,0,0" ToolTip="点击切换配色：暗夜 → 白昼 → 深海 → 翡翠 → 樱花"/>
    </Grid>
  </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlText)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    function Find([string]$Name) { return $window.FindName($Name) }

    # 默认尺寸按屏幕工作区收缩：高分屏 150% 缩放下 1080p 工作区高度不足 760 DIU，
    # 不收缩会让标题栏顶出屏幕、窗口拖不动也放不大（2026-07-11 用户实锤）。
    try {
        $workArea = [System.Windows.SystemParameters]::WorkArea
        if ($window.MinWidth -gt ($workArea.Width - 12)) { $window.MinWidth = [math]::Max(600, $workArea.Width - 12) }
        if ($window.MinHeight -gt ($workArea.Height - 12)) { $window.MinHeight = [math]::Max(480, $workArea.Height - 12) }
        if ($window.Width -gt ($workArea.Width - 12)) { $window.Width = [math]::Max($window.MinWidth, $workArea.Width - 12) }
        if ($window.Height -gt ($workArea.Height - 12)) { $window.Height = [math]::Max($window.MinHeight, $workArea.Height - 12) }
    } catch { }

    # ---------- 主题应用与持久化（记忆存 tmp\，不进工具包） ----------
    $ThemeFile = Join-Path $Root 'tmp\panel-theme.txt'
    $script:ThemeIndex = 0
    function Apply-Theme([int]$Index, [bool]$Save) {
        $script:ThemeIndex = (($Index % $Themes.Count) + $Themes.Count) % $Themes.Count
        $theme = $Themes[$script:ThemeIndex]
        foreach ($kv in $theme.C.GetEnumerator()) {
            # 注意：不能写 $window.Resources[$key] = $brush —— PowerShell 对 ResourceDictionary
            # 索引器赋值会把 Brush 错误转换成 Color，触发 "not a valid value" 崩溃；必须 Remove+Add。
            $window.Resources.Remove($kv.Key)
            $window.Resources.Add($kv.Key, (New-Brush ([string]$kv.Value)))
        }
        $btnTheme = Find 'btnTheme'
        if ($btnTheme) { $btnTheme.Content = ('主题：' + $theme.Name) }
        if ($Save) {
            try {
                $tmpDir = Join-Path $Root 'tmp'
                if (-not (Test-Path -LiteralPath $tmpDir -PathType Container)) {
                    [void](New-Item -ItemType Directory -Path $tmpDir -Force)
                }
                [System.IO.File]::WriteAllText($ThemeFile, $theme.Name, (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
        }
    }
    $savedTheme = ''
    try {
        if (Test-Path -LiteralPath $ThemeFile -PathType Leaf) {
            $savedTheme = ([System.IO.File]::ReadAllText($ThemeFile, (New-Object System.Text.UTF8Encoding($false)))).Trim()
        }
    } catch { }
    $initIndex = 0
    for ($i = 0; $i -lt $Themes.Count; $i++) {
        if ($Themes[$i].Name -eq $savedTheme) { $initIndex = $i; break }
    }
    Apply-Theme $initIndex $false
    (Find 'btnTheme').Add_Click({ Apply-Theme ($script:ThemeIndex + 1) $true })

    # ---------- 状态行构建 ----------
    $statusList = Find 'statusList'
    $StatusRows = @{}
    function Add-StatusRow([string]$Key, [string]$Label) {
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = '0,3,0,3'
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = 'Auto'
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '96'
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
        [void]$grid.ColumnDefinitions.Add($c0); [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)

        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 9; $dot.Height = 9; $dot.Margin = '0,0,8,0'
        $dot.VerticalAlignment = 'Center'
        $dot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'ThOff')
        [System.Windows.Controls.Grid]::SetColumn($dot, 0)

        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $Label
        $name.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'ThTextMain')
        $name.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($name, 1)

        $value = New-Object System.Windows.Controls.TextBlock
        $value.Text = '…'
        $value.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'ThTextDim')
        $value.VerticalAlignment = 'Center'; $value.TextTrimming = 'CharacterEllipsis'
        [System.Windows.Controls.Grid]::SetColumn($value, 2)

        [void]$grid.Children.Add($dot); [void]$grid.Children.Add($name); [void]$grid.Children.Add($value)
        [void]$statusList.Children.Add($grid)
        $StatusRows[$Key] = @{ Dot = $dot; Value = $value }
    }
    Add-StatusRow 'server'  'MC 服务端'
    Add-StatusRow 'update'  '更新服务'
    Add-StatusRow 'watch'   '通知监控'
    # Discord 反控组件只随私用包分发；公开包（QQ 方案）没有该文件时不显示这一行
    if (Test-Path -LiteralPath (Join-Path $ToolsDir 'DiscordConsoleBridge.java') -PathType Leaf) {
        Add-StatusRow 'console' 'Discord 反控'
    }
    Add-StatusRow 'qq'      'QQ 桥接'
    Add-StatusRow 'backup'  '备份调度'
    Add-StatusRow 'perf'    '性能黑匣子'
    Add-StatusRow 'rcon'    'RCON'

    function Set-StatusRow([string]$Key, [string]$State, [string]$Text) {
        $row = $StatusRows[$Key]
        if (-not $row) { return }
        $res = 'ThOff'
        if ($State -eq 'good') { $res = 'ThGood' }
        elseif ($State -eq 'bad') { $res = 'ThBad' }
        elseif ($State -eq 'warn') { $res = 'ThWarn' }
        $row.Dot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $res)
        $row.Value.Text = $Text
    }

    # ---------- 整合包信息行 ----------
    $packInfoList = Find 'packInfoList'
    $PackRows = @{}
    function Add-PackRow([string]$Key, [string]$Label) {
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = '0,3,0,3'
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '78'
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
        [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $Label
        $name.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'ThTextDim')
        [System.Windows.Controls.Grid]::SetColumn($name, 0)
        $value = New-Object System.Windows.Controls.TextBlock
        $value.Text = '—'
        $value.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'ThTextMain')
        $value.TextTrimming = 'CharacterEllipsis'; $value.ToolTip = ''
        [System.Windows.Controls.Grid]::SetColumn($value, 1)
        [void]$grid.Children.Add($name); [void]$grid.Children.Add($value)
        [void]$packInfoList.Children.Add($grid)
        $PackRows[$Key] = $value
    }
    Add-PackRow 'name'     '整合包'
    Add-PackRow 'version'  '版本'
    Add-PackRow 'detected' '本服检测'
    Add-PackRow 'address'  '服务器'
    Add-PackRow 'source'   '主客户端'
    Add-PackRow 'updsrc'   '更新源'

    function Set-PackRow([string]$Key, [string]$Text, [bool]$Warn = $false) {
        $tb = $PackRows[$Key]
        if (-not $tb) { return }
        $tb.Text = $Text; $tb.ToolTip = $Text
        $res = if ($Warn) { 'ThWarn' } else { 'ThTextMain' }
        $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $res)
    }

    # ---------- 性能监控行 ----------
    $perfList = Find 'perfList'
    $PerfRows = @{}
    function Add-PerfRow([string]$Key, [string]$Label) {
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = '0,3,0,3'
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '84'
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
        [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $Label
        $name.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'ThTextDim')
        [System.Windows.Controls.Grid]::SetColumn($name, 0)
        $value = New-Object System.Windows.Controls.TextBlock
        $value.Text = '…'
        $value.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'ThTextMain')
        $value.TextTrimming = 'CharacterEllipsis'; $value.ToolTip = ''
        [System.Windows.Controls.Grid]::SetColumn($value, 1)
        [void]$grid.Children.Add($name); [void]$grid.Children.Add($value)
        [void]$perfList.Children.Add($grid)
        $PerfRows[$Key] = $value
    }
    Add-PerfRow 'procmem' '服务端内存'
    Add-PerfRow 'world'   '世界大小'
    Add-PerfRow 'backup'  '备份占用'

    function Set-PerfRow([string]$Key, [string]$Text, [bool]$Warn = $false) {
        $tb = $PerfRows[$Key]
        if (-not $tb) { return }
        $tb.Text = $Text; $tb.ToolTip = $Text
        $res = if ($Warn) { 'ThWarn' } else { 'ThTextMain' }
        $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $res)
    }

    function Format-PanelBytes([double]$Bytes) {
        if ($Bytes -lt 0) { return '—' }
        if ($Bytes -lt 1MB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
        if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
        return ('{0:N2} GB' -f ($Bytes / 1GB))
    }

    # 系统内存用 GlobalMemoryStatusEx（P/Invoke 即时返回；CIM/WMI 每次查询上百毫秒，会卡 UI 线程）
    $MemInfoType = $null
    try {
        $MemInfoType = (Add-Type -PassThru -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PanelNative {
    public static class MemInfo {
        [StructLayout(LayoutKind.Sequential)]
        private struct MEMORYSTATUSEX {
            public uint dwLength; public uint dwMemoryLoad;
            public ulong ullTotalPhys; public ulong ullAvailPhys;
            public ulong ullTotalPageFile; public ulong ullAvailPageFile;
            public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);
        public static ulong[] Query() {
            MEMORYSTATUSEX m = new MEMORYSTATUSEX();
            m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            if (!GlobalMemoryStatusEx(ref m)) return null;
            return new ulong[] { m.ullTotalPhys, m.ullAvailPhys, (ulong)m.dwMemoryLoad };
        }
    }
}
'@) | Select-Object -First 1
    } catch { $MemInfoType = $null }

    # ---------- 环形占比仪表（服务端CPU / 整机GPU / 内存 / 磁盘） ----------
    # 72×72 网格里：Ellipse 画满圈轨道，Path(ArcSegment) 画占比弧（圆心 36,36 半径 25.75，与轨道同轨），
    # 中心叠数值+副标，颜色按负载档位在 ThGood/ThWarn/ThBad 之间切（走 SetResourceReference，换肤自动跟随）。
    $gaugePanel = Find 'gaugePanel'
    $Gauges = @{}
    function New-Gauge([string]$Key, [string]$Label, [string]$Tip) {
        $holder = New-Object System.Windows.Controls.StackPanel
        $holder.HorizontalAlignment = 'Center'
        if ($Tip) { $holder.ToolTip = $Tip }
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Width = 72; $grid.Height = 72
        $track = New-Object System.Windows.Shapes.Ellipse
        $track.Width = 58; $track.Height = 58
        $track.StrokeThickness = 6.5
        $track.HorizontalAlignment = 'Center'; $track.VerticalAlignment = 'Center'
        $track.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'ThBtnBase')
        $arc = New-Object System.Windows.Shapes.Path
        $arc.StrokeThickness = 6.5
        $arc.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
        $arc.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
        $arc.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'ThGood')
        $mid = New-Object System.Windows.Controls.StackPanel
        $mid.HorizontalAlignment = 'Center'; $mid.VerticalAlignment = 'Center'
        $val = New-Object System.Windows.Controls.TextBlock
        $val.Text = '—'; $val.FontSize = 13; $val.FontWeight = 'SemiBold'
        $val.HorizontalAlignment = 'Center'
        $val.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'ThTextMain')
        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Text = ''; $sub.FontSize = 8.5
        $sub.HorizontalAlignment = 'Center'
        $sub.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'ThTextDim')
        [void]$mid.Children.Add($val); [void]$mid.Children.Add($sub)
        [void]$grid.Children.Add($track); [void]$grid.Children.Add($arc); [void]$grid.Children.Add($mid)
        $lab = New-Object System.Windows.Controls.TextBlock
        $lab.Text = $Label; $lab.FontSize = 11
        $lab.HorizontalAlignment = 'Center'; $lab.Margin = '0,2,0,0'
        $lab.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'ThTextDim')
        [void]$holder.Children.Add($grid); [void]$holder.Children.Add($lab)
        [void]$gaugePanel.Children.Add($holder)
        $Gauges[$Key] = @{ Arc = $arc; Val = $val; Sub = $sub }
    }
    # CPU 环 = 服务端进程占用（MC 主刻循环单线程 CPU 密集，TPS 掉=它顶不住）；
    # 服务端本身不碰 GPU（无渲染），GPU 环监控整机（本机常兼跑客户端/推流等）。
    # 环心地方小，说明性文字一律放 ToolTip，副标只留短词。
    New-Gauge 'cpu'  'CPU'  'Minecraft 服务端进程的 CPU 占用（按全部核心折算）。TPS 下降多半是它单核顶不住。'
    New-Gauge 'gpu'  'GPU'  '整机 GPU 占用（取最忙引擎，口径同任务管理器）。MC 服务端本身不使用 GPU，此环反映本机整体：客户端、推流、视频等。'
    New-Gauge 'mem'  '内存' '整机物理内存占用；服务端进程自身的内存见下方「服务端内存」一行。'
    New-Gauge 'disk' '磁盘' '服务端所在磁盘的空间占用；世界和备份的具体体积见下方两行。'

    function Get-LoadColorKey([double]$Pct, [double]$WarnAt, [double]$BadAt) {
        if ($Pct -ge $BadAt) { return 'ThBad' }
        if ($Pct -ge $WarnAt) { return 'ThWarn' }
        return 'ThGood'
    }

    $InvCulture = [System.Globalization.CultureInfo]::InvariantCulture
    function Set-Gauge([string]$Key, [double]$Pct, [string]$ValText, [string]$SubText, [string]$ColorKey) {
        $g = $Gauges[$Key]
        if (-not $g) { return }
        $g.Val.Text = $ValText
        $g.Sub.Text = $SubText
        $g.Arc.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, $ColorKey)
        if ($Pct -lt 0) { $Pct = 0 }
        if ($Pct -gt 100) { $Pct = 100 }
        if ($Pct -le 0.3) { $g.Arc.Data = $null; return }
        $sweep = 360.0 * $Pct / 100.0
        if ($sweep -gt 359.5) { $sweep = 359.5 } # 满 360° 起终点重合会画成空，压到 359.5°
        $r = 25.75
        $cx = 36.0
        $rad0 = -90.0 * [math]::PI / 180.0
        $rad1 = ($sweep - 90.0) * [math]::PI / 180.0
        $x0 = $cx + $r * [math]::Cos($rad0); $y0 = $cx + $r * [math]::Sin($rad0)
        $x1 = $cx + $r * [math]::Cos($rad1); $y1 = $cx + $r * [math]::Sin($rad1)
        $large = if ($sweep -gt 180.0) { 1 } else { 0 }
        # Geometry.Parse 只认不变量文化的小数点，禁用 -f（跟随当前区域设置）
        $pathText = [string]::Format($InvCulture, 'M {0:0.##},{1:0.##} A {2},{2} 0 {3} 1 {4:0.##},{5:0.##}', $x0, $y0, $r, $large, $x1, $y1)
        $g.Arc.Data = [System.Windows.Media.Geometry]::Parse($pathText)
    }

    # ---------- 负载趋势迷你曲线（60 个采样 × 5 秒 ≈ 最近 5 分钟，右侧生长） ----------
    $sparkCanvas = Find 'sparkCanvas'
    $script:SparkCpu = New-Object 'System.Collections.Generic.List[double]'
    $script:SparkMem = New-Object 'System.Collections.Generic.List[double]'
    $sparkFill = New-Object System.Windows.Shapes.Polygon
    $sparkFill.Opacity = 0.14
    $sparkFill.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'ThGood')
    $sparkMemLine = New-Object System.Windows.Shapes.Polyline
    $sparkMemLine.StrokeThickness = 1.4
    $sparkMemLine.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'ThWarn')
    $sparkCpuLine = New-Object System.Windows.Shapes.Polyline
    $sparkCpuLine.StrokeThickness = 1.7
    $sparkCpuLine.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
    $sparkCpuLine.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'ThGood')
    [void]$sparkCanvas.Children.Add($sparkFill)
    [void]$sparkCanvas.Children.Add($sparkMemLine)
    [void]$sparkCanvas.Children.Add($sparkCpuLine)

    function Update-Sparkline([double]$CpuPct, [double]$MemPct) {
        [void]$script:SparkCpu.Add([math]::Max(0.0, [math]::Min(100.0, $CpuPct)))
        [void]$script:SparkMem.Add([math]::Max(0.0, [math]::Min(100.0, $MemPct)))
        while ($script:SparkCpu.Count -gt 60) { $script:SparkCpu.RemoveAt(0) }
        while ($script:SparkMem.Count -gt 60) { $script:SparkMem.RemoveAt(0) }
        $n = $script:SparkCpu.Count
        if ($n -lt 2) { return }
        $w = $sparkCanvas.ActualWidth
        if ($w -lt 20) { $w = 270 }
        $h = 46.0
        $step = $w / 59.0
        $x0 = $w - ($n - 1) * $step
        $cpuPts = New-Object System.Windows.Media.PointCollection
        $memPts = New-Object System.Windows.Media.PointCollection
        $fillPts = New-Object System.Windows.Media.PointCollection
        $fillPts.Add((New-Object System.Windows.Point($x0, $h)))
        for ($i = 0; $i -lt $n; $i++) {
            $x = $x0 + $i * $step
            $cy = $h - 2.0 - ($script:SparkCpu[$i] / 100.0) * ($h - 4.0)
            $my = $h - 2.0 - ($script:SparkMem[$i] / 100.0) * ($h - 4.0)
            $cpuPts.Add((New-Object System.Windows.Point($x, $cy)))
            $memPts.Add((New-Object System.Windows.Point($x, $my)))
            $fillPts.Add((New-Object System.Windows.Point($x, $cy)))
        }
        $fillPts.Add((New-Object System.Windows.Point(($x0 + ($n - 1) * $step), $h)))
        $sparkCpuLine.Points = $cpuPts
        $sparkMemLine.Points = $memPts
        $sparkFill.Points = $fillPts
    }

    # ---------- 整机 GPU 占用后台采样 ----------
    # GPU Engine 性能计数器单次采样约 3 秒（本机实测 732 个实例），绝不能在 UI 线程跑；
    # 常驻后台 runspace 循环采样写入同步哈希表，UI 每次刷新只读共享值。
    # 取值口径同任务管理器：按 engtype 分组求和后取最忙引擎（避免 3D+解码+复制 叠加超 100%）。
    # 类别名 "GPU Engine" 在中文 Windows 上也是英文（dxgkrnl 注册的计数器不本地化，本机实测）。
    $script:GpuState = [hashtable]::Synchronized(@{ Pct = -2.0 })   # -2=采样中，-1=不可用，>=0=百分比
    $script:GpuPS = $null
    try {
        $gpuPs = [powershell]::Create()
        [void]$gpuPs.AddScript({
            param($State)
            $failStreak = 0
            while ($true) {
                $pct = -1.0
                try {
                    $samples = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples
                    $byType = @{}
                    foreach ($s in $samples) {
                        if ($s.InstanceName -match 'engtype_([A-Za-z0-9 ]+)') {
                            $t = $matches[1]
                            $byType[$t] = [double]$byType[$t] + $s.CookedValue
                        }
                    }
                    $max = 0.0
                    foreach ($v in $byType.Values) { if ($v -gt $max) { $max = $v } }
                    $pct = [math]::Min(100.0, $max)
                } catch { $pct = -1.0 }
                if ($pct -ge 0) {
                    $failStreak = 0
                    $State['Pct'] = $pct
                    Start-Sleep -Seconds 3
                } else {
                    # 首次/偶发采样失败别急着报「不可用」（2026-07-11 实锤面板刚开会闪现该状态）：
                    # 保持「采样中」快速重试，连挂 3 次才降级为不可用并降频重试
                    $failStreak++
                    if ($failStreak -ge 3) {
                        $State['Pct'] = -1.0
                        Start-Sleep -Seconds 30
                    } else {
                        Start-Sleep -Seconds 3
                    }
                }
            }
        }).AddArgument($script:GpuState)
        $script:GpuPS = $gpuPs
        [void]$gpuPs.BeginInvoke()
    } catch { $script:GpuState['Pct'] = -1.0 }

    # 服务端 CPU%：两次采样 TotalProcessorTime 求差（刷新周期 5 秒，够平滑）
    $script:PerfPrev = $null
    function Update-Perf([int]$ServerPid) {
        $proc = $null
        if ($ServerPid -gt 0) { $proc = Get-Process -Id $ServerPid -ErrorAction SilentlyContinue }
        $cpuPct = 0.0
        if ($proc) {
            $now = [DateTime]::UtcNow
            $cpuSec = 0.0
            try { $cpuSec = $proc.TotalProcessorTime.TotalSeconds } catch { }
            $cpuText = '…'
            if ($script:PerfPrev -and $script:PerfPrev.ProcId -eq $ServerPid) {
                $dt = ($now - $script:PerfPrev.Stamp).TotalSeconds
                if ($dt -ge 1) {
                    $cpuPct = ($cpuSec - $script:PerfPrev.Cpu) / $dt / [Environment]::ProcessorCount * 100
                    if ($cpuPct -lt 0) { $cpuPct = 0 }
                    if ($cpuPct -gt 100) { $cpuPct = 100 }
                    $cpuText = ('{0:N1}%' -f $cpuPct)
                }
            }
            $script:PerfPrev = @{ ProcId = $ServerPid; Cpu = $cpuSec; Stamp = $now }
            Set-Gauge 'cpu' $cpuPct $cpuText ('{0} 核' -f [Environment]::ProcessorCount) (Get-LoadColorKey $cpuPct 60 85)
            Set-PerfRow 'procmem' ('{0:N0} MB（提交 {1:N0} MB）' -f ($proc.WorkingSet64 / 1MB), ($proc.PrivateMemorySize64 / 1MB))
        } else {
            $script:PerfPrev = $null
            Set-Gauge 'cpu' 0 '—' '未开服' 'ThOff'
            Set-PerfRow 'procmem' '未开服'
        }
        $gpuPct = -1.0
        try { $gpuPct = [double]$script:GpuState['Pct'] } catch { }
        if ($gpuPct -ge 0) {
            Set-Gauge 'gpu' $gpuPct ('{0:N0}%' -f $gpuPct) '整机' (Get-LoadColorKey $gpuPct 70 90)
        } elseif ($gpuPct -le -1.5) {
            Set-Gauge 'gpu' 0 '…' '采样中' 'ThOff'
        } else {
            Set-Gauge 'gpu' 0 '—' '不可用' 'ThOff'
        }
        $memPct = 0.0
        if ($MemInfoType) {
            $m = $MemInfoType::Query()
            if ($m) {
                $memPct = [double]$m[2]
                $memSub = ('{0:N1}/{1:N1}G' -f (([double]$m[0] - [double]$m[1]) / 1GB), ([double]$m[0] / 1GB))
                Set-Gauge 'mem' $memPct ('{0:N0}%' -f $memPct) $memSub (Get-LoadColorKey $memPct 75 90)
            }
        }
        try {
            $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($Root))
            $free = [double]$drive.AvailableFreeSpace
            $total = [double]$drive.TotalSize
            $diskPct = if ($total -gt 0) { 100.0 - $free / $total * 100.0 } else { 0.0 }
            Set-Gauge 'disk' $diskPct ('{0:N0}%' -f $diskPct) ('余 {0:N0}G' -f ($free / 1GB)) (Get-LoadColorKey $diskPct 80 92)
        } catch { Set-Gauge 'disk' 0 '—' '' 'ThOff' }
        try { Update-Sparkline $cpuPct $memPct } catch { }
    }

    # 世界/备份占用：目录可能几十 GB，绝不在 UI 线程上算，丢后台 runspace 每分钟扫一次
    $script:SizePS = $null
    $script:SizeHandle = $null
    function Start-SizeScan {
        if ($script:SizeHandle) { return }
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            param($RootDir)
            function Get-DirSize([string]$Path) {
                if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return -1L }
                $sum = 0L
                foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) { $sum += $f.Length }
                return $sum
            }
            @{
                World  = Get-DirSize (Join-Path $RootDir 'world')
                Backup = Get-DirSize (Join-Path $RootDir 'backups')
            }
        }).AddArgument($Root)
        $script:SizePS = $ps
        $script:SizeHandle = $ps.BeginInvoke()
    }
    function Complete-SizeScanIfDone {
        if (-not $script:SizeHandle) { return }
        if (-not $script:SizeHandle.IsCompleted) { return }
        $data = $null
        try { $data = ($script:SizePS.EndInvoke($script:SizeHandle) | Select-Object -First 1) } catch { }
        try { $script:SizePS.Dispose() } catch { }
        $script:SizePS = $null
        $script:SizeHandle = $null
        if ($data) {
            Set-PerfRow 'world' $(if ([long]$data.World -ge 0) { Format-PanelBytes ([double]$data.World) } else { '还没有 world 目录' })
            Set-PerfRow 'backup' $(if ([long]$data.Backup -ge 0) { Format-PanelBytes ([double]$data.Backup) } else { '还没有备份' })
        }
    }

    # 本机实测服务端版本/加载器（扫 libraries，独立于配置文件），用于揪出「配置是上个服带来的」。
    function Get-LocalServerDetection {
        $forgeRoot = Join-Path $Root 'libraries\net\minecraftforge\forge'
        if (Test-Path -LiteralPath $forgeRoot -PathType Container) {
            $d = Get-ChildItem -LiteralPath $forgeRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($d -and $d.Name -match '^(?<mc>[0-9]+(\.[0-9]+){1,2})-(?<v>.+)$') {
                return @{ Loader = 'forge'; LoaderVersion = $matches.v; Mc = $matches.mc }
            }
        }
        $neoRoot = Join-Path $Root 'libraries\net\neoforged\neoforge'
        if (Test-Path -LiteralPath $neoRoot -PathType Container) {
            $d = Get-ChildItem -LiteralPath $neoRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($d) {
                # NeoForge → MC 版本反推分两个时代：
                #   1.x：前两段对应 MC（21.1.x → 1.21.1；21.0.x → 1.21）
                #   26.x 新纪年（2026 起）：NeoForge = MC版本.构建号（26.1.2.78 → MC 26.1.2；26.2.0.x → MC 26.2）
                $mc = ''
                if ($d.Name -match '^(?<a>\d+)\.(?<b>\d+)\.(?<c>\d+)') {
                    $a = [int]$matches.a; $b = [int]$matches.b; $c = [int]$matches.c
                    if ($a -ge 26) {
                        $mc = if ($c -eq 0) { ('{0}.{1}' -f $a, $b) } else { ('{0}.{1}.{2}' -f $a, $b, $c) }
                    } else {
                        $mc = if ($b -eq 0) { '1.' + $a } else { ('1.{0}.{1}' -f $a, $b) }
                    }
                }
                return @{ Loader = 'neoforge'; LoaderVersion = $d.Name; Mc = $mc }
            }
        }
        $fabRoot = Join-Path $Root 'libraries\net\fabricmc\fabric-loader'
        if (Test-Path -LiteralPath $fabRoot -PathType Container) {
            $d = Get-ChildItem -LiteralPath $fabRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($d) { return @{ Loader = 'fabric'; LoaderVersion = $d.Name; Mc = '' } }
        }
        return $null
    }

    # ---------- 输出日志 ----------
    $txtOutput = Find 'txtOutput'
    function Write-PanelLog([string]$Message) {
        $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
        if ([string]::IsNullOrEmpty($txtOutput.Text)) {
            $txtOutput.AppendText($line)
        } else {
            $txtOutput.AppendText([Environment]::NewLine + $line)
        }
        $txtOutput.ScrollToEnd()
    }

    # ---------- 数据读取 ----------
    function Read-ServerProperties {
        $props = @{}
        $path = Join-Path $Root 'server.properties'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            foreach ($line in [System.IO.File]::ReadAllLines($path)) {
                if ($line -match '^\s*([^#=]+)=(.*)$') { $props[$matches[1].Trim()] = $matches[2] }
            }
        }
        return $props
    }

    function Read-PackConfig {
        $path = Join-Path $ToolsDir 'portable-pack.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        try {
            return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
        } catch {
            return $null
        }
    }

    # 端口监听检测的性能关键路径：本函数每 5 秒在 UI 线程跑两次（服务端口 + 更新服务端口）。
    # Get-NetTCPConnection 是 CIM 查询、单次上百毫秒，会造成滚动/悬停卡顿（2026-07-11 用户实锤），
    # 所以先用纯托管 GetActiveTcpListeners()（微秒级）判断是否在监听；只在首次发现监听时
    # 才用一次 CIM 拿 PID 并缓存，之后按缓存 PID 是否存活校验，端口不再监听时清缓存。
    $script:ListenPidCache = @{}
    function Get-ListeningPid([int]$Port) {
        if ($Port -le 0) { return 0 }
        $listening = $false
        try {
            foreach ($ep in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
                if ($ep.Port -eq $Port) { $listening = $true; break }
            }
        } catch { }
        if (-not $listening) {
            [void]$script:ListenPidCache.Remove($Port)
            return 0
        }
        $cached = $script:ListenPidCache[$Port]
        if ($cached -and (Get-Process -Id ([int]$cached) -ErrorAction SilentlyContinue)) { return [int]$cached }
        try {
            $conn = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
            if ($conn.Count -gt 0) {
                $script:ListenPidCache[$Port] = [int]$conn[0].OwningProcess
                return [int]$conn[0].OwningProcess
            }
        } catch { }
        return 0
    }

    # PID 会被系统回收给无关进程，只凭 Get-Process -Id 会把「浏览器恰好拿到旧 PID」误报成运维在跑。
    # 判据：运维进程必然在写 PID 文件之前就已启动；被回收的 PID 其启动时间必然晚于文件写入时间。
    # 走进程 StartTime 而不是查命令行：本函数每 5 秒在 UI 线程跑 4 次，CIM 查询会直接卡住滚动。
    function Get-PidFileAlive([string]$RelPath) {
        $path = Join-Path $Root $RelPath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 0 }
        $raw = ''
        try { $raw = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop) } catch { return 0 }
        $procId = 0
        if (-not [int]::TryParse($raw.Trim(), [ref]$procId)) { return 0 }
        if ($procId -le 0) { return 0 }
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $proc) { return 0 }
        try { $started = $proc.StartTime } catch { return 0 }
        try {
            $stamp = (Get-Item -LiteralPath $path -ErrorAction Stop).LastWriteTime
            if ($started -gt $stamp.AddSeconds(60)) { return 0 }   # PID 已被回收给别的进程
        } catch { }
        return $procId
    }

    # ---------- 状态刷新 ----------
    $txtLastRefresh = Find 'txtLastRefresh'
    $txtRconState = Find 'txtRconState'
    $script:RconEnabled = $false

    function Update-Status {
        $props = Read-ServerProperties
        $pack = Read-PackConfig

        # MC 服务端：按 server-port 是否有进程监听判断
        $serverPort = 25565
        if ($props.ContainsKey('server-port')) {
            $tmpPort = 0
            if ([int]::TryParse(([string]$props['server-port']).Trim(), [ref]$tmpPort) -and $tmpPort -gt 0) { $serverPort = $tmpPort }
        }
        $serverPid = Get-ListeningPid $serverPort
        if ($serverPid -gt 0) {
            Set-StatusRow 'server' 'good' ("运行中 · 端口 {0} · PID {1}" -f $serverPort, $serverPid)
        } else {
            Set-StatusRow 'server' 'bad' ("未监听端口 {0}（未开服或仍在启动）" -f $serverPort)
        }
        try { Update-Perf $serverPid } catch { }

        # 更新服务
        if ($pack -and $pack.update -and $pack.update.port) {
            $updPort = [int]$pack.update.port
            $updPid = Get-ListeningPid $updPort
            if ($updPid -gt 0) {
                Set-StatusRow 'update' 'good' ("运行中 · 端口 {0}" -f $updPort)
            } else {
                Set-StatusRow 'update' 'off' ("未开启 · 配置端口 {0}" -f $updPort)
            }
        } else {
            Set-StatusRow 'update' 'off' '未配置（先跑初始化配置向导）'
        }

        # 运维监控 PID 文件
        $monitors = @(
            @{ Key = 'watch';   File = 'tmp\discord-watch.pid' },
            @{ Key = 'console'; File = 'tmp\discord-console.pid' },
            @{ Key = 'qq';      File = 'tmp\qq-console.pid' },
            @{ Key = 'backup';  File = 'tmp\backup-scheduler.pid' },
            @{ Key = 'perf';    File = 'tmp\perf-sampler.pid' }
        )
        $qqAlive = $false
        foreach ($m in $monitors) {
            $alive = Get-PidFileAlive $m.File
            if ($alive -gt 0) {
                if ($m.Key -eq 'qq') { $qqAlive = $true }
                Set-StatusRow $m.Key 'good' ("运行中 · PID {0}" -f $alive)
            } else {
                Set-StatusRow $m.Key 'off' '未运行'
            }
        }

        # RCON
        $script:RconEnabled = $false
        if (($props['enable-rcon'] -as [string]) -eq 'true') {
            $rconPort = 0
            [void][int]::TryParse(([string]$props['rcon.port']).Trim(), [ref]$rconPort)
            $hasPwd = -not [string]::IsNullOrWhiteSpace([string]$props['rcon.password'])
            if ($hasPwd) {
                $script:RconEnabled = $true
                Set-StatusRow 'rcon' 'good' ("已启用 · 端口 {0}" -f $rconPort)
                $txtRconState.Text = ("RCON 端口 {0}" -f $rconPort)
            } else {
                Set-StatusRow 'rcon' 'warn' '已启用但密码为空'
                $txtRconState.Text = 'RCON 密码为空'
            }
        } else {
            Set-StatusRow 'rcon' 'off' '未启用（点「启用 RCON 反控」）'
            $txtRconState.Text = 'RCON 未启用'
        }

        # 整合包信息（不显示 token/webhook 等敏感项）
        # 本机实测行：不看配置文件，直接扫 libraries
        $det = Get-LocalServerDetection
        if ($det) {
            $detText = if ([string]::IsNullOrWhiteSpace($det.Mc)) { '{0} {1}' -f $det.Loader, $det.LoaderVersion } else { '{0} · {1} {2}' -f $det.Mc, $det.Loader, $det.LoaderVersion }
            Set-PackRow 'detected' $detText
        } else {
            Set-PackRow 'detected' '未识别（还没有服务端文件）'
        }

        if ($pack) {
            $packName = [string]$pack.packName
            if ([string]::IsNullOrWhiteSpace($packName)) { $packName = '未填写（跑初始化配置向导）' }
            Set-PackRow 'name' $packName
            $loaderText = ''
            if ($pack.loader) { $loaderText = ('{0} {1}' -f [string]$pack.loader.type, [string]$pack.loader.version).Trim() }
            $verText = ([string]$pack.minecraftVersion).Trim()
            if (-not [string]::IsNullOrWhiteSpace($loaderText)) { $verText = ("$verText · $loaderText").Trim(' ·') }

            # 配置与本机实测不符 → 黄牌警告（典型场景：私包/旧配置带到了新服务端）
            $mismatch = $false
            if ($det) {
                $packLoaderType = ''
                if ($pack.loader) { $packLoaderType = ([string]$pack.loader.type).Trim().ToLowerInvariant() }
                $packMc = ([string]$pack.minecraftVersion).Trim()
                if ($packLoaderType -and $det.Loader -and ($packLoaderType -ne $det.Loader)) { $mismatch = $true }
                if ($packMc -and $det.Mc -and ($packMc -ne $det.Mc)) { $mismatch = $true }
            }
            if ([string]::IsNullOrWhiteSpace($verText)) {
                Set-PackRow 'version' '未填写（跑初始化配置向导）'
            } elseif ($mismatch) {
                Set-PackRow 'version' ($verText + '（与本服检测不符）') $true
                if (-not $script:StaleConfigWarned) {
                    $script:StaleConfigWarned = $true
                    Write-PanelLog ('[警告] 配置文件里的版本/加载器与本服检测不符（本服是 ' + $detText + '），像是上一个服务端带来的旧配置。请点「初始化配置向导」重新识别，向导里可以自定义整合包名称。')
                }
            } else {
                Set-PackRow 'version' $verText
            }

            $addr = ''
            if ($pack.server) { $addr = [string]$pack.server.address }
            if ([string]::IsNullOrWhiteSpace($addr)) { $addr = '—' }
            Set-PackRow 'address' $addr
            $src = [string]$pack.sourceClient
            if ([string]::IsNullOrWhiteSpace($src)) {
                Set-PackRow 'source' '未设置（点击这里选择目录）' $true
            } else {
                $srcFull = if ([System.IO.Path]::IsPathRooted($src)) { $src } else { Join-Path $Root $src }
                if (Test-Path -LiteralPath $srcFull -PathType Container) {
                    Set-PackRow 'source' $src
                } else {
                    Set-PackRow 'source' ($src + '（目录不存在）') $true
                }
            }
            if ($pack.update) {
                Set-PackRow 'updsrc' ('{0}://{1}:{2}' -f [string]$pack.update.scheme, [string]$pack.update.host, [string]$pack.update.port)
            } else {
                Set-PackRow 'updsrc' '—'
            }
        } else {
            Set-PackRow 'name' '未配置（跑初始化配置向导）' $true
            Set-PackRow 'version' '—'
            Set-PackRow 'address' '—'
            Set-PackRow 'source' '—'
            Set-PackRow 'updsrc' '—'
        }

        # 常用设置开关的当前值
        foreach ($cd in @(
            @{ Name = 'chipOnline';    Key = 'online-mode'; Label = '正版验证' },
            @{ Name = 'chipWhitelist'; Key = 'white-list';  Label = '白名单' },
            @{ Name = 'chipPvp';       Key = 'pvp';         Label = 'PVP' }
        )) {
            $chipBtn = Find $cd.Name
            if (-not $chipBtn) { continue }
            if ($props.Count -eq 0) {
                $chipBtn.Content = $cd.Label + '：—'
            } else {
                $chipBtn.Content = $cd.Label + '：' + $(if ((([string]$props[$cd.Key]).Trim()) -eq 'true') { '开' } else { '关' })
            }
        }
        $chipDiff = Find 'chipDifficulty'
        if ($chipDiff) {
            $chipDiff.Content = if ($props.Count -eq 0) { '难度：—' } else { '难度：' + (Get-DifficultyCn ([string]$props['difficulty'])) }
        }

        # 上手路线点亮
        $srcOk = $false
        if ($pack) {
            $srcVal = [string]$pack.sourceClient
            if (-not [string]::IsNullOrWhiteSpace($srcVal)) {
                $srcFull2 = if ([System.IO.Path]::IsPathRooted($srcVal)) { $srcVal } else { Join-Path $Root $srcVal }
                $srcOk = (Test-Path -LiteralPath $srcFull2 -PathType Container)
            }
        }
        $pubOk = $false
        if ($pack) {
            $pubDir = [string]$pack.publishDir
            if ([string]::IsNullOrWhiteSpace($pubDir)) { $pubDir = '.\modpack-public\portable' }
            $pubFull = if ([System.IO.Path]::IsPathRooted($pubDir)) { $pubDir } else { Join-Path $Root $pubDir }
            $pubOk = (Test-Path -LiteralPath (Join-Path $pubFull 'server-manifest.json') -PathType Leaf)
        }
        $updOn = $false
        if ($pack -and $pack.update -and $pack.update.port) { $updOn = ((Get-ListeningPid ([int]$pack.update.port)) -gt 0) }
        Update-GuideSteps @{
            qq      = $qqAlive
            wizard  = [bool]($pack -and -not [string]::IsNullOrWhiteSpace([string]$pack.packId) -and -not [string]::IsNullOrWhiteSpace([string]$pack.packName))
            client  = $srcOk
            server  = ($serverPid -gt 0)
            publish = $pubOk
            update  = $updOn
        }

        $txtLastRefresh.Text = ('每 5 秒自动刷新 · 上次：{0}' -f (Get-Date -Format 'HH:mm:ss'))
    }

    # ---------- 一键入口调度 ----------
    function Start-BatEntry([string]$BatName) {
        # 一键 bat 自 2026-07 起收纳在「一键脚本」子目录；兼容旧版直接放根目录的布局
        $batPath = Join-Path $Root (Join-Path '一键脚本' $BatName)
        if (-not (Test-Path -LiteralPath $batPath -PathType Leaf)) {
            $batPath = Join-Path $Root $BatName
        }
        if (-not (Test-Path -LiteralPath $batPath -PathType Leaf)) {
            Write-PanelLog ("[缺失] 一键脚本\{0} 不存在，请确认工具包完整。" -f $BatName)
            return
        }
        try {
            Start-Process -FilePath $env:ComSpec -WorkingDirectory $Root -ArgumentList @('/d', '/c', ('"' + $batPath + '"'))
            Write-PanelLog ("已启动：{0}（请在新窗口中继续操作）" -f $BatName)
        } catch {
            Write-PanelLog ("[失败] 无法启动 {0}：{1}" -f $BatName, $_.Exception.Message)
        }
    }

    # 直接调度 tools 下的 ps1（和一键 bat 一样在新可见窗口运行；禁止加 -WindowStyle Hidden，杀软实锤）
    function Start-ToolScript([string]$ScriptName, [string[]]$ExtraArgs, [string]$Label) {
        $scriptPath = Join-Path $ToolsDir $ScriptName
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            Write-PanelLog ("[缺失] 找不到 tools\{0}，请确认工具包完整。" -f $ScriptName)
            return
        }
        # Start-Process 的 ArgumentList 不会自动给带空格的路径加引号（服务端目录名常带空格），必须手动包引号
        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $scriptPath + '"')) + @($ExtraArgs)
        try {
            Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Root -ArgumentList $psArgs
            Write-PanelLog ("已启动：{0}（请在新窗口确认结果）" -f $Label)
        } catch {
            Write-PanelLog ("[失败] 无法启动 {0}：{1}" -f $Label, $_.Exception.Message)
        }
    }
    (Find 'btnRconOff').Add_Click({
        Start-ToolScript 'enable-local-rcon.ps1' @('-Disable') '关闭 RCON'
    })

    $BatButtons = @{
        btnWizard       = '一键便携-初始化配置.bat'
        btnQQSetup      = '一键便携-配置QQ机器人.bat'
        btnRcon         = '一键便携-启用RCON反控.bat'
        btnUpdateServer = '一键便携-开启更新服务.bat'
        btnOpsRestart   = '一键便携-重启运维监控.bat'
        btnOpsStart     = '一键便携-启动所有运维.bat'
        btnOpsStop      = '一键便携-停止所有运维.bat'
        btnQQStart      = '一键便携-启动QQ机器人.bat'
        btnQQTest       = '一键便携-测试QQ机器人.bat'
        btnPublish      = '一键便携-仅发布更新.bat'
        btnImportPack   = '一键便携-生成规范导入包.bat'
        btnFullPack     = '一键便携-生成完整包.bat'
        btnKitPublic    = '一键生成便携工具包.bat'
        btnKitLite      = '一键生成精简工具包.bat'
        btnKitPrivate   = '一键生成私用便携工具包.bat'
         btnHealthCheck  = '一键便携-健康体检.bat'
         btnWeeklyReport = '一键便携-运行报告.bat'
         btnIncidentPostmortem = '一键便携-事故自动复盘.bat'
         btnBlueMapTimeMachine = '一键便携-BlueMap时光机.bat'
         btnVerifyBackup = '一键便携-验证备份.bat'
        btnOpsTimeline = '一键便携-运维时间线.bat'
    }
    # 诊断包：直接带 -Pack 调脚本（不走 bat，避免 bat 参数解析差异）
    $btnHealthPack = Find 'btnHealthPack'
    if ($btnHealthPack) {
        $btnHealthPack.Add_Click({
            Start-ToolScript 'health-check.ps1' @('-Pack') '健康体检（含诊断包）'
        })
    }
    foreach ($entry in $BatButtons.GetEnumerator()) {
        $button = Find $entry.Key
        if ($button) {
            $button.Tag = $entry.Value
            $button.Add_Click({ param($sender, $e) Start-BatEntry ([string]$sender.Tag) })
        }
    }
    # 「生成工具包」是作者操作：公开/精简包不带这些 bat，按钮自动隐藏（使用者只看到「检查更新」）
    foreach ($authorBtnName in @('btnKitPublic', 'btnKitLite', 'btnKitPrivate')) {
        $authorBtn = Find $authorBtnName
        if (-not $authorBtn) { continue }
        $authorBat = [string]$BatButtons[$authorBtnName]
        $inSub = Test-Path -LiteralPath (Join-Path $Root (Join-Path '一键脚本' $authorBat)) -PathType Leaf
        $inRoot = Test-Path -LiteralPath (Join-Path $Root $authorBat) -PathType Leaf
        if (-not ($inSub -or $inRoot)) { $authorBtn.Visibility = [System.Windows.Visibility]::Collapsed }
    }

    # ---------- 检查更新（像常规软件那样：比对版本 → 弹窗展示更新日志 → 一键更新并重启面板） ----------
    function Read-KitZipInfo([string]$ZipPath) {
        $info = @{ Version = ''; Changelog = '' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            foreach ($spec in @(@{ Name = 'KIT-VERSION.txt'; Key = 'Version' }, @{ Name = 'KIT-CHANGELOG.txt'; Key = 'Changelog' })) {
                $e = $z.Entries | Where-Object { $_.FullName -eq $spec.Name } | Select-Object -First 1
                if ($e) {
                    $sr = New-Object System.IO.StreamReader($e.Open(), [System.Text.Encoding]::UTF8)
                    $info[$spec.Key] = $sr.ReadToEnd().Trim()
                    $sr.Dispose()
                }
            }
        } finally { $z.Dispose() }
        return $info
    }
    # ---------- 更新包下载：后台 runspace（绝不在 UI 线程下载）----------
    # 主工具包 zip 有数十 MB，早先直接在 UI 线程 WebClient.DownloadFile，整个窗口会僵住、
    # 标题栏显示「未响应」直到下载完。现改用与世界体积扫描同一套异步模式：后台线程分块下载并
    # 把进度写进同步哈希表，UI 定时器每秒读一次刷新按钮文字，下载完再回 UI 线程比对版本、弹窗。
    $script:KitCheckPS = $null
    $script:KitCheckHandle = $null
    $script:KitProgress = $null
    $script:KitZipPath = ''

    function Start-KitDownload([string]$Url, [string]$Dest) {
        $script:KitProgress = [hashtable]::Synchronized(@{ Done = [int64]0; Total = [int64]0; Error = ''; Finished = $false })
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            param($Url, $Dest, $State)
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
                $req = [System.Net.HttpWebRequest]::Create($Url)
                $req.Timeout = 30000          # 建连/响应头
                $req.ReadWriteTimeout = 120000 # 单次读取
                $req.UserAgent = 'PortableServerKit-Panel/1.0'
                $resp = $req.GetResponse()
                $State['Total'] = [int64]$resp.ContentLength
                $in = $resp.GetResponseStream()
                $fs = [System.IO.File]::Open($Dest, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try {
                    $buf = New-Object byte[] 131072
                    while ($true) {
                        $n = $in.Read($buf, 0, $buf.Length)
                        if ($n -le 0) { break }
                        $fs.Write($buf, 0, $n)
                        $State['Done'] = [int64]$State['Done'] + $n
                    }
                } finally {
                    try { $fs.Dispose() } catch { }
                    try { $in.Dispose() } catch { }
                    try { $resp.Dispose() } catch { }
                }
            } catch {
                $State['Error'] = $_.Exception.Message
            } finally {
                $State['Finished'] = $true
            }
        }).AddArgument($Url).AddArgument($Dest).AddArgument($script:KitProgress)
        $script:KitCheckPS = $ps
        $script:KitCheckHandle = $ps.BeginInvoke()
    }

    # 由 1 秒定时器调用：下载中刷新进度，完成后接回版本比对
    function Complete-KitCheckIfDone {
        if (-not $script:KitCheckHandle) { return }
        $btn = Find 'btnKitUpdate'
        $st = $script:KitProgress
        if (-not $st['Finished']) {
            if ($btn) {
                $done = [int64]$st['Done']; $total = [int64]$st['Total']
                $btn.Content = if ($total -gt 0) { '下载中 {0:N0}%' -f ($done * 100.0 / $total) }
                               else { '下载中 {0:N1} MB' -f ($done / 1MB) }
            }
            return
        }
        try { [void]$script:KitCheckPS.EndInvoke($script:KitCheckHandle) } catch { }
        try { $script:KitCheckPS.Dispose() } catch { }
        $script:KitCheckPS = $null
        $script:KitCheckHandle = $null
        if ($btn) { $btn.Content = '检查更新'; $btn.IsEnabled = $true }
        $err = [string]$st['Error']
        if (-not [string]::IsNullOrWhiteSpace($err)) {
            Write-PanelLog ('[失败] 无法连接更新服务器：' + $err)
            return
        }
        Write-PanelLog ('更新包下载完成（{0:N1} MB），正在比对版本…' -f ([int64]$st['Done'] / 1MB))
        Show-KitUpdateDecision $script:KitZipPath
    }

    function Invoke-KitCheckUpdate {
        if ($script:KitCheckHandle) { Write-PanelLog '[提示] 更新包正在下载中，请稍候。'; return }
        $srcCfg = Join-Path $ToolsDir 'toolkit-update-source.txt'
        $src = ''
        if (Test-Path -LiteralPath $srcCfg -PathType Leaf) { $src = (Get-Content -LiteralPath $srcCfg -Raw -Encoding UTF8).Trim() }
        if ([string]::IsNullOrWhiteSpace($src)) {
            Write-PanelLog '[提示] 未配置更新源：在 tools\toolkit-update-source.txt 写入主工具包 zip 的路径或下载 URL 即可使用检查更新。'
            return
        }
        $zipPath = $src
        if ($src -match '^(?i)https?://') {
            $zipPath = Join-Path $Root 'tmp\toolkit-check.zip'
            New-Item -ItemType Directory -Force (Join-Path $Root 'tmp') | Out-Null
            $script:KitZipPath = $zipPath
            $btn = Find 'btnKitUpdate'
            if ($btn) { $btn.IsEnabled = $false; $btn.Content = '下载中…' }
            Write-PanelLog '正在从更新服务器下载更新包（后台进行，面板可继续操作）…'
            Start-KitDownload $src $zipPath
            return   # 余下流程由 Complete-KitCheckIfDone 接手
        }
        # 本地 zip 更新源：读盘很快，仍走同步路径
        if (-not [System.IO.Path]::IsPathRooted($zipPath)) { $zipPath = [System.IO.Path]::GetFullPath((Join-Path $Root $zipPath)) }
        $rootFull2 = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
        if ($zipPath.StartsWith($rootFull2 + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-PanelLog '[提示] 本目录就是主发布目录，无需自更新；改进后点「生成工具包」即为发布。'
            return
        }
        if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
            Write-PanelLog ('[失败] 更新源 zip 不存在：' + $zipPath)
            return
        }
        Show-KitUpdateDecision $zipPath
    }

    # 版本比对 → 展示更新日志 → 确认后拉起更新器并关闭面板（下载与否都走这里）
    function Show-KitUpdateDecision([string]$zipPath) {
        $info = $null
        try { $info = Read-KitZipInfo $zipPath } catch {
            Write-PanelLog ('[失败] 读取更新包失败：' + $_.Exception.Message)
            return
        }
        if ([string]::IsNullOrWhiteSpace($info.Version)) {
            Write-PanelLog '[失败] 更新包里没有版本信息（KIT-VERSION.txt），请联系作者重新发布。'
            return
        }
        $curVer = '(未记录)'
        $cvPath = Join-Path $Root 'KIT-VERSION.txt'
        if (Test-Path -LiteralPath $cvPath -PathType Leaf) { $curVer = (Get-Content -LiteralPath $cvPath -Raw -Encoding UTF8).Trim() }
        if ($curVer -eq $info.Version) {
            Write-PanelLog ('检查更新：已是最新版本 ' + $curVer + '。')
            [void][System.Windows.MessageBox]::Show(('已是最新版本：' + $curVer), '检查更新', 'OK', 'Information')
            return
        }
        $changelog = $info.Changelog
        if ([string]::IsNullOrWhiteSpace($changelog)) { $changelog = '（此版本未附更新日志）' }
        if ($changelog.Length -gt 1200) { $changelog = $changelog.Substring(0, 1200) + [Environment]::NewLine + '……（完整日志见更新后根目录的 KIT-CHANGELOG.txt）' }
        $msg = "发现新版本：$($info.Version)`n当前版本：$curVer`n`n更新内容：`n$changelog`n`n现在更新并重启控制面板吗？`n（本服 pack/ops 配置不会被覆盖，改动前自动备份）"
        $choice = [System.Windows.MessageBox]::Show($msg, '发现工具包新版本', 'YesNo', 'Question')
        if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
            Write-PanelLog '已取消更新。'
            return
        }
        $updater = Join-Path $ToolsDir 'update-toolkit.ps1'
        if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
            Write-PanelLog '[失败] 缺少 tools\update-toolkit.ps1，请确认工具包完整。'
            return
        }
        # ArgumentList 不自动加引号：路径（常含空格/中文目录名）必须手动包引号，否则更新器进程秒败闪退
        Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Root -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $updater + '"'), '-SourceZip', ('"' + $zipPath + '"'), '-RestartPanel')
        Write-PanelLog '更新进行中：本面板即将关闭，更新完成后会自动重新打开。'
        $window.Close()
    }
    (Find 'btnKitUpdate').Add_Click({ Invoke-KitCheckUpdate })

    # ---------- 日志 / 目录快捷键 ----------
    function Open-TextFile([string]$RelPath) {
        $path = Join-Path $Root $RelPath
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $path + '"')
        } else {
            Write-PanelLog ("[提示] 文件还不存在：{0}" -f $RelPath)
        }
    }
    function Open-FolderWindow([string]$Path, [string]$Label) {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Path + '"')
        } else {
            Write-PanelLog ("[提示] 目录还不存在：{0}" -f $Label)
        }
    }
    function Open-Folder([string]$RelPath) {
        Open-FolderWindow (Join-Path $Root $RelPath) $RelPath
    }
    # 主客户端目录来自 pack 配置 sourceClient（相对根目录或绝对路径），点击时现读，改完配置立即生效。
    function Open-ClientFolder([string]$Sub) {
        $pack = Read-PackConfig
        $src = ''
        if ($pack) { $src = [string]$pack.sourceClient }
        if ([string]::IsNullOrWhiteSpace($src)) {
            Write-PanelLog '[提示] 还没有主客户端：点「选择主客户端…」指定任意目录（不必在服务端目录内）；如果还没有客户端，可在根目录新建「客户端」文件夹放入整合包客户端实例（从玩家包/规范导入包解压即可），再跑「初始化配置向导」。'
            return
        }
        $base = $src
        if (-not [System.IO.Path]::IsPathRooted($base)) {
            $base = [System.IO.Path]::GetFullPath((Join-Path $Root $src))
        }
        if (-not (Test-Path -LiteralPath $base -PathType Container)) {
            Write-PanelLog ('[提示] 配置里的主客户端目录在本机不存在：' + $base + '。多半是旧服带来的路径——点「选择主客户端…」重新指定，或跑「初始化配置向导」。')
            return
        }
        $target = $base
        $label = '主客户端根目录'
        if (-not [string]::IsNullOrWhiteSpace($Sub)) {
            $target = Join-Path $base $Sub
            $label = "主客户端 $Sub"
        }
        Open-FolderWindow $target ("{0}（{1}）" -f $label, $target)
    }

    # 「选择主客户端」：面板唯一允许写配置的例外——只改 sourceClient 一个字段，写前自动备份到 backups\panel-config。
    function Save-PackSourceClient([string]$NewPath) {
        $packPath = Join-Path $ToolsDir 'portable-pack.json'
        if (-not (Test-Path -LiteralPath $packPath -PathType Leaf)) {
            Write-PanelLog '[失败] 还没有 tools\portable-pack.json：先跑一次「初始化配置向导」生成配置，再来选择主客户端。'
            return $false
        }
        try {
            $json = Get-Content -LiteralPath $packPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-PanelLog ('[失败] portable-pack.json 解析失败：' + $_.Exception.Message)
            return $false
        }
        try {
            $bakDir = Join-Path $Root 'backups\panel-config'
            New-Item -ItemType Directory -Force $bakDir | Out-Null
            Copy-Item -LiteralPath $packPath -Destination (Join-Path $bakDir ('portable-pack-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Force
            if ($json.PSObject.Properties['sourceClient']) { $json.sourceClient = $NewPath }
            else { $json | Add-Member -NotePropertyName 'sourceClient' -NotePropertyValue $NewPath }
            $out = $json | ConvertTo-Json -Depth 100
            # PS5.1 的 ConvertTo-Json 会把中文转成 \uXXXX，写回前还原（只还原非 ASCII，控制字符仍保持转义）
            $out = [regex]::Replace($out, '\\u([0-9a-fA-F]{4})', {
                param($m)
                $cp = [Convert]::ToInt32($m.Groups[1].Value, 16)
                if ($cp -ge 0x80) { [string][char]$cp } else { $m.Value }
            })
            [System.IO.File]::WriteAllText($packPath, $out + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
            return $true
        } catch {
            Write-PanelLog ('[失败] 写入 sourceClient 失败：' + $_.Exception.Message)
            return $false
        }
    }
    $OpenActions = @{
        btnLogServer   = { Open-TextFile 'logs\latest.log' }
        btnLogWrapper  = { Open-TextFile 'logs\server-wrapper.log' }
        btnLogDiscord  = { Open-TextFile 'logs\discord-watch.log' }
        btnLogQQ       = { Open-TextFile 'logs\qq-console.log' }
        btnOpenServerMods = { Open-Folder 'mods' }
        btnOpenClientMods = { Open-ClientFolder 'mods' }
        btnOpenClientRoot = { Open-ClientFolder '' }
        btnOpenRoot    = { Open-Folder '.' }
        btnOpenDist    = { Open-Folder 'dist' }
        btnOpenPackJson = { Open-TextFile 'tools\portable-pack.json' }
        btnOpenOpsJson  = { Open-TextFile 'tools\ops-config.json' }
    }
    foreach ($entry in $OpenActions.GetEnumerator()) {
        $button = Find $entry.Key
        if ($button) { $button.Add_Click($entry.Value) }
    }

    # 三个入口共用：日志与目录「选择主客户端…」、①配置「选择分发客户端目录」、整合包信息「主客户端」行点击
    function Invoke-PickClient {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择主分发客户端目录（含 mods 的实例目录；可以在服务端目录外的任意位置）'
        $dlg.ShowNewFolderButton = $true
        $pack = Read-PackConfig
        if ($pack -and -not [string]::IsNullOrWhiteSpace([string]$pack.sourceClient)) {
            $cur = [string]$pack.sourceClient
            if (-not [System.IO.Path]::IsPathRooted($cur)) { $cur = [System.IO.Path]::GetFullPath((Join-Path $Root $cur)) }
            if (Test-Path -LiteralPath $cur -PathType Container) { $dlg.SelectedPath = $cur }
        }
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $picked = $dlg.SelectedPath
        # 在服务端根目录内就存相对路径（随目录整体迁移仍有效），在外面才存绝对路径
        $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
        $store = $picked
        if ($picked.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $store = '.\' + $picked.Substring($rootFull.Length + 1)
        }
        if (-not (Test-Path -LiteralPath (Join-Path $picked 'mods') -PathType Container)) {
            Write-PanelLog ('[提示] 所选目录下没有 mods 子目录：' + $picked + '。仍已写入配置，但请确认这确实是整合包客户端实例目录。')
        }
        if (Save-PackSourceClient $store) {
            Write-PanelLog ('主客户端已设置为：' + $store)
            try { Update-Status } catch { }
        }
    }
    foreach ($pickBtnName in @('btnPickClient', 'btnPickClientCfg')) {
        $pickBtn = Find $pickBtnName
        if ($pickBtn) { $pickBtn.Add_Click({ Invoke-PickClient }) }
    }
    # 「主客户端」行本身可点：新服还没配置时这是最顺眼的入口
    $srcRowText = $PackRows['source']
    if ($srcRowText) {
        $srcRowText.Cursor = [System.Windows.Input.Cursors]::Hand
        $srcRowText.TextDecorations = [System.Windows.TextDecorations]::Underline
        $srcRowText.Add_MouseLeftButtonUp({ Invoke-PickClient })
    }

    # ---------- 服务端启动/重启/停止 ----------
    # 重启 = 安全 stop（世界先保存），看门狗 10 秒后自动拉起；
    # 停止 = 先写 maintenance.stop 标记再安全 stop，看门狗见标记不重启；启动时自动清标记。
    function Start-ServerWithClearFlag {
        $ms = Join-Path $Root 'maintenance.stop'
        if (Test-Path -LiteralPath $ms -PathType Leaf) {
            Remove-Item -LiteralPath $ms -Force -Confirm:$false -ErrorAction SilentlyContinue
            Write-PanelLog '已清除停服标记 maintenance.stop。'
        }
        Start-BatEntry '一键便携-启动服务端.bat'
    }
    (Find 'btnStartServer').Add_Click({ Start-ServerWithClearFlag })
    (Find 'btnRestartServer').Add_Click({
        if (-not $script:RconEnabled) {
            Write-PanelLog '[提示] 面板重启需要 RCON：先点「启用 RCON 反控」并重启一次服务端；当下可在服务端控制台窗口输入 stop，看门狗会自动重启。'
            return
        }
        $ms = Join-Path $Root 'maintenance.stop'
        if (Test-Path -LiteralPath $ms -PathType Leaf) { Remove-Item -LiteralPath $ms -Force -Confirm:$false -ErrorAction SilentlyContinue }
        Invoke-RconCommand 'stop'
        Write-PanelLog '已发送安全停服命令：世界保存后退出，看门狗 10 秒后自动拉起新进程。'
    })
    (Find 'btnStopServer').Add_Click({
        $ms = Join-Path $Root 'maintenance.stop'
        try {
            [System.IO.File]::WriteAllText($ms, ('panel stop ' + (Get-Date -Format 's') + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            Write-PanelLog ('[失败] 无法写入停服标记：' + $_.Exception.Message)
            return
        }
        if ($script:RconEnabled) {
            Invoke-RconCommand 'stop'
            Write-PanelLog '已写入停服标记并发送安全停服命令：世界保存后退出，不会自动重启。下次点「启动服务端」会自动清除标记。'
        } else {
            Write-PanelLog '已写入停服标记 maintenance.stop（禁止自动重启）。RCON 未启用无法远程停服：请在服务端控制台窗口输入 stop 完成停服。'
        }
    })

    # ---------- 常用设置（server.properties 快捷开关）----------
    # 面板允许写配置的第二个例外：只改单个键值，写入前自动备份，改完提示需重启。
    function Set-ServerProperty([string]$Key, [string]$Value) {
        $path = Join-Path $Root 'server.properties'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-PanelLog '[提示] 还没有 server.properties，先启动一次服务端让它生成。'
            return $false
        }
        try {
            $lines = New-Object 'System.Collections.Generic.List[string]'
            $lines.AddRange([string[]][System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8))
            $found = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = [string]$lines[$i]
                if ($line -match '^\s*#') { continue }
                $eq = $line.IndexOf('=')
                if ($eq -lt 1) { continue }
                if ([string]::Equals($line.Substring(0, $eq).Trim().Trim([char]0xFEFF), $Key, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $lines[$i] = "$Key=$Value"
                    $found = $true
                }
            }
            if (-not $found) { [void]$lines.Add("$Key=$Value") }
            $bakDir = Join-Path $Root 'backups\panel-config'
            New-Item -ItemType Directory -Force $bakDir | Out-Null
            Copy-Item -LiteralPath $path -Destination (Join-Path $bakDir ('server.properties-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Force
            [System.IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
            return $true
        } catch {
            Write-PanelLog ('[失败] 写入 server.properties：' + $_.Exception.Message)
            return $false
        }
    }
    $DifficultyOrder = @('peaceful', 'easy', 'normal', 'hard')
    $DifficultyCn = @{ peaceful = '和平'; easy = '简单'; normal = '普通'; hard = '困难'; '0' = '和平'; '1' = '简单'; '2' = '普通'; '3' = '困难' }
    function Get-DifficultyCn([string]$Raw) {
        $k = ([string]$Raw).Trim().ToLowerInvariant()
        if ($DifficultyCn.ContainsKey($k)) { return $DifficultyCn[$k] }
        if ([string]::IsNullOrWhiteSpace($k)) { return '—' }
        return $Raw
    }
    $BoolToggles = @{
        chipOnline    = @{ Key = 'online-mode'; Label = '正版验证' }
        chipWhitelist = @{ Key = 'white-list';  Label = '白名单' }
        chipPvp       = @{ Key = 'pvp';         Label = 'PVP' }
    }
    foreach ($entry in $BoolToggles.GetEnumerator()) {
        $button = Find $entry.Key
        if (-not $button) { continue }
        $button.Tag = $entry.Value
        $button.Add_Click({
            param($sender, $e)
            $meta = $sender.Tag
            $props = Read-ServerProperties
            if ($props.Count -eq 0) { Write-PanelLog '[提示] 还没有 server.properties，先启动一次服务端让它生成。'; return }
            $cur = (([string]$props[$meta.Key]).Trim() -eq 'true')
            $new = if ($cur) { 'false' } else { 'true' }
            if (Set-ServerProperty $meta.Key $new) {
                Write-PanelLog ('已把 {0}（{1}）改为「{2}」，重启 Minecraft 服务端后生效。' -f $meta.Label, $meta.Key, $(if ($new -eq 'true') { '开' } else { '关' }))
                try { Update-Status } catch { }
            }
        })
    }
    (Find 'chipDifficulty').Add_Click({
        $props = Read-ServerProperties
        if ($props.Count -eq 0) { Write-PanelLog '[提示] 还没有 server.properties，先启动一次服务端让它生成。'; return }
        $curRaw = ([string]$props['difficulty']).Trim().ToLowerInvariant()
        $numMap = @{ '0' = 'peaceful'; '1' = 'easy'; '2' = 'normal'; '3' = 'hard' }
        if ($numMap.ContainsKey($curRaw)) { $curRaw = $numMap[$curRaw] }
        $idx = [array]::IndexOf($DifficultyOrder, $curRaw)
        $next = $DifficultyOrder[(($idx + 1) % $DifficultyOrder.Count)]
        if (Set-ServerProperty 'difficulty' $next) {
            Write-PanelLog ('已把难度改为「{0}」（{1}），重启 Minecraft 服务端后生效。' -f (Get-DifficultyCn $next), $next)
            try { Update-Status } catch { }
        }
    })

    # ---------- 上手路线（实时点亮，点击直达）----------
    $guidePanel = Find 'guideSteps'
    $txtGuideHint = Find 'txtGuideHint'
    $GuideDefs = @(
        @{ Key = 'wizard';  Label = '① 初始化配置'; Hint = '先跑向导：自动识别本服版本，给整合包起名' }
        @{ Key = 'client';  Label = '② 选主客户端'; Hint = '告诉面板整合包客户端目录在哪（可在服务端目录外）' }
        @{ Key = 'server';  Label = '③ 启动服务端'; Hint = '配置就绪，点这一步开服（Java 会自动匹配）' }
        @{ Key = 'publish'; Label = '④ 发布更新';   Hint = '把主客户端内容发布成玩家更新源' }
        @{ Key = 'update';  Label = '⑤ 开更新服务'; Hint = '开启后玩家即可同步，整条链路就通了' }
        @{ Key = 'qq';      Label = '⑥ QQ 机器人'; Hint = '想在 QQ 群收通知/反控就配它'; Optional = $true }
    )
    $GuideButtons = @{}
    foreach ($def in $GuideDefs) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $def.Label
        $b.Style = $window.FindResource('ChipButton')
        $b.Tag = $def.Key
        [void]$guidePanel.Children.Add($b)
        $GuideButtons[$def.Key] = $b
    }
    $GuideButtons['wizard'].Add_Click({ Start-BatEntry '一键便携-初始化配置.bat' })
    $GuideButtons['client'].Add_Click({ Invoke-PickClient })
    $GuideButtons['server'].Add_Click({ Start-ServerWithClearFlag })
    $GuideButtons['publish'].Add_Click({ Start-BatEntry '一键便携-仅发布更新.bat' })
    $GuideButtons['update'].Add_Click({ Start-BatEntry '一键便携-开启更新服务.bat' })
    $GuideButtons['qq'].Add_Click({ Start-BatEntry '一键便携-配置QQ机器人.bat' })
    function Update-GuideSteps($Done) {
        $currentFound = $false
        $currentHint = ''
        $optionalPending = $false
        foreach ($def in $GuideDefs) {
            $b = $GuideButtons[$def.Key]
            if ($Done[$def.Key]) {
                $b.Content = '✓ ' + $def.Label
                $b.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'ThGood')
            } elseif ($def.Optional) {
                # 可选步骤不占用「当前步」，未完成也不拦 🎉
                $optionalPending = $true
                $b.Content = $def.Label + '（可选）'
                $b.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'ThTextDim')
            } elseif (-not $currentFound) {
                $currentFound = $true
                $b.Content = '▶ ' + $def.Label
                $b.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'ThWarn')
                $currentHint = '下一步：' + $def.Hint
            } else {
                $b.Content = $def.Label
                $b.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'ThTextDim')
            }
        }
        if (-not $currentFound) {
            $currentHint = '🎉 核心五步全部完成！日常用「重启运维监控」和「仅发布更新」即可。'
            if ($optionalPending) { $currentHint += ' 想要 QQ 群通知/反控可点「⑥ QQ 机器人」。' }
        }
        $txtGuideHint.Text = $currentHint
    }

    # ---------- 备份管理 ----------
    $lstBackups = Find 'lstBackups'
    $cmbBackupDate = Find 'cmbBackupDate'
    $txtBackupStats = Find 'txtBackupStats'
    $script:BackupRefreshing = $false

    function Get-BackupZips {
        $dir = Join-Path $Root 'backups\world'
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
        return @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    }

    function Update-BackupList {
        $script:BackupRefreshing = $true
        try {
            $zips = Get-BackupZips
            $totalBytes = 0L
            foreach ($z in $zips) { $totalBytes += $z.Length }
            if ($zips.Count -eq 0) {
                $txtBackupStats.Text = '还没有世界备份'
            } else {
                $txtBackupStats.Text = ('共 {0} 份 · 占用 {1} · 最新 {2}' -f $zips.Count, (Format-PanelBytes ([double]$totalBytes)), $zips[0].LastWriteTime.ToString('MM-dd HH:mm'))
            }
            # 日期下拉：全部 + 每个有备份的日期（新在前），刷新时尽量保住原选择
            $dates = @($zips | ForEach-Object { $_.LastWriteTime.ToString('yyyy-MM-dd') } | Select-Object -Unique)
            $prevPick = [string]$cmbBackupDate.SelectedItem
            $cmbBackupDate.Items.Clear()
            [void]$cmbBackupDate.Items.Add('全部日期')
            foreach ($d in $dates) { [void]$cmbBackupDate.Items.Add($d) }
            $cmbBackupDate.SelectedIndex = 0
            if ($prevPick -and $cmbBackupDate.Items.Contains($prevPick)) { $cmbBackupDate.SelectedItem = $prevPick }
            $pick = [string]$cmbBackupDate.SelectedItem
            $lstBackups.Items.Clear()
            foreach ($z in $zips) {
                $day = $z.LastWriteTime.ToString('yyyy-MM-dd')
                if ($pick -and $pick -ne '全部日期' -and $day -ne $pick) { continue }
                $item = New-Object System.Windows.Controls.ListBoxItem
                $item.Content = ('{0} {1}  {2,10}  {3}' -f $day, $z.LastWriteTime.ToString('HH:mm:ss'), (Format-PanelBytes ([double]$z.Length)), $z.Name)
                $item.Tag = $z.FullName
                $item.ToolTip = $z.FullName
                [void]$lstBackups.Items.Add($item)
            }
        } finally { $script:BackupRefreshing = $false }
    }
    $cmbBackupDate.Add_SelectionChanged({ if (-not $script:BackupRefreshing) { Update-BackupList } })

    (Find 'btnBackupNow').Add_Click({
        Start-ToolScript 'backup-world.ps1' @() '立即备份世界'
    })
    (Find 'btnBackupRefresh').Add_Click({ Update-BackupList; Write-PanelLog '备份列表已刷新。' })
    (Find 'btnBackupOpen').Add_Click({ Open-Folder 'backups\world' })
    (Find 'btnBackupDelete').Add_Click({
        $sel = @($lstBackups.SelectedItems)
        if ($sel.Count -eq 0) { Write-PanelLog '[提示] 先在列表里选中要删除的备份（Ctrl/Shift 可多选）。'; return }
        $bytes = 0L
        foreach ($it in $sel) { try { $bytes += (Get-Item -LiteralPath ([string]$it.Tag)).Length } catch { } }
        $msg = ('确定删除选中的 {0} 份备份（共 {1}）吗？{2}删除后无法恢复！' -f $sel.Count, (Format-PanelBytes ([double]$bytes)), [Environment]::NewLine)
        $choice = [System.Windows.MessageBox]::Show($msg, '删除备份', 'YesNo', 'Warning')
        if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { return }
        $ok = 0; $fail = 0
        foreach ($it in $sel) {
            try {
                Remove-Item -LiteralPath ([string]$it.Tag) -Force -Confirm:$false
                $ok++
            } catch {
                $fail++
                Write-PanelLog ('[失败] 删除 ' + [string]$it.Tag + '：' + $_.Exception.Message)
            }
        }
        Write-PanelLog ('备份删除完成：成功 {0} 份{1}。' -f $ok, $(if ($fail -gt 0) { ('，失败 ' + $fail + ' 份') } else { '' }))
        Update-BackupList
        Start-SizeScan   # 让左栏「备份占用」尽快跟上
    })
    $lstBackups.Add_MouseDoubleClick({
        $it = $lstBackups.SelectedItem
        if ($it -and $it.Tag) {
            try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + [string]$it.Tag + '"') } catch { }
        }
    })

    # ---------- 服务端下载与安装 ----------
    # 面板只负责弹文件夹选择器 + 调度 tools\install-server.ps1，全部下载/安装逻辑都在向导脚本里
    function Start-InstallServer([string]$Dir) {
        Start-ToolScript 'install-server.ps1' @('-TargetDir', ('"' + $Dir + '"')) '服务端下载安装向导'
    }
    (Find 'btnInstallPick').Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择新服务端的安装目录（建议新建一个空文件夹）'
        $dlg.ShowNewFolderButton = $true
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        Start-InstallServer $dlg.SelectedPath
    })
    (Find 'btnInstallHere').Add_Click({
        $msg = '将在当前服务端目录运行下载安装向导（重装/升级核心）：' + [Environment]::NewLine + $Root + [Environment]::NewLine + [Environment]::NewLine + 'world、mods 等数据不会被删除，但同名核心文件会被覆盖。继续吗？'
        $choice = [System.Windows.MessageBox]::Show($msg, '安装到当前目录', 'YesNo', 'Question')
        if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { return }
        Start-InstallServer $Root
    })

    # ---------- RCON 异步执行 ----------
    $txtRconInput = Find 'txtRconInput'
    $btnRconSend = Find 'btnRconSend'
    $script:RconPS = $null
    $script:RconHandle = $null
    $script:RconCmdShown = ''

    function Invoke-RconCommand([string]$Command) {
        $Command = $Command.Trim()
        if ([string]::IsNullOrWhiteSpace($Command)) { return }
        if (-not $script:RconEnabled) {
            Write-PanelLog '[RCON] 尚未启用：先点「启用 RCON 反控」，并重启 Minecraft 服务端。'
            return
        }
        if ($script:RconHandle) {
            Write-PanelLog '[RCON] 上一条命令还在执行，请稍候。'
            return
        }
        $rconScript = Join-Path $ToolsDir 'rcon-command.ps1'
        $script:RconCmdShown = $Command
        Write-PanelLog ("[RCON] > {0}" -f $Command)
        $btnRconSend.IsEnabled = $false
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            param($ScriptPath, $Cmd)
            try {
                $out = & $ScriptPath -Command $Cmd 2>&1 | Out-String
                if ([string]::IsNullOrWhiteSpace($out)) { '(服务器没有返回内容)' } else { $out.TrimEnd() }
            } catch {
                '[RCON 失败] ' + $_.Exception.Message
            }
        }).AddArgument($rconScript).AddArgument($Command)
        $script:RconPS = $ps
        $script:RconHandle = $ps.BeginInvoke()
    }

    function Complete-RconIfDone {
        if (-not $script:RconHandle) { return }
        if (-not $script:RconHandle.IsCompleted) { return }
        $text = ''
        try {
            $result = $script:RconPS.EndInvoke($script:RconHandle)
            $text = ($result | Out-String).TrimEnd()
        } catch {
            $text = '[RCON 失败] ' + $_.Exception.Message
        }
        try { $script:RconPS.Dispose() } catch { }
        $script:RconPS = $null
        $script:RconHandle = $null
        $btnRconSend.IsEnabled = $true
        if ([string]::IsNullOrWhiteSpace($text)) { $text = '(服务器没有返回内容)' }
        Write-PanelLog $text
    }

    $btnRconSend.Add_Click({
        Invoke-RconCommand $txtRconInput.Text
        $txtRconInput.Clear()
    })
    $txtRconInput.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
            Invoke-RconCommand $txtRconInput.Text
            $txtRconInput.Clear()
            $e.Handled = $true
        }
    })

    $ChipCommands = @{
        chipList    = 'list'
        chipDay     = 'time set day'
        chipWeather = 'weather clear'
        chipSave    = 'save-all flush'
    }
    foreach ($entry in $ChipCommands.GetEnumerator()) {
        $button = Find $entry.Key
        if ($button) {
            $button.Tag = $entry.Value
            $button.Add_Click({ param($sender, $e) Invoke-RconCommand ([string]$sender.Tag) })
        }
    }
    # TPS 命令随加载器变化：Forge=forge tps，NeoForge=neoforge tps，其他（Fabric/Quilt/原版）没有内置命令，
    # 退回裸 tps（装了 Carpet 等提供 /tps 的 mod 就能用，没装会返回未知命令，无副作用）。
    (Find 'chipTps').Add_Click({
        $pack = Read-PackConfig
        $loaderType = ''
        if ($pack -and $pack.loader) { $loaderType = ([string]$pack.loader.type).Trim().ToLowerInvariant() }
        $cmd = 'tps'
        if ($loaderType -eq 'forge') { $cmd = 'forge tps' }
        elseif ($loaderType -eq 'neoforge') { $cmd = 'neoforge tps' }
        Invoke-RconCommand $cmd
    })

    # ---------- 其他控件 ----------
    (Find 'txtRootPath').Text = $Root
    (Find 'btnRefresh').Add_Click({ Update-Status; Write-PanelLog '状态已手动刷新。' })

    # ---------- 定时器：1 秒轮询 RCON 结果，5 秒刷新状态 ----------
    $script:TickCount = 0
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
        Complete-RconIfDone
        try { Complete-SizeScanIfDone } catch { }
        try { Complete-KitCheckIfDone } catch { }
        $script:TickCount++
        if (($script:TickCount % 5) -eq 0) {
            try { Update-Status } catch { }
        }
        if (($script:TickCount % 60) -eq 0) {
            try { Start-SizeScan } catch { }
        }
    })

    $window.Add_ContentRendered({
        Hide-HostConsole
        try { Update-Status } catch { Write-PanelLog ('[警告] 状态刷新失败：' + $_.Exception.Message) }
        try { Update-BackupList } catch { }
        try { Start-SizeScan } catch { }
        $timer.Start()
        Write-PanelLog '控制面板就绪。按钮会在新窗口执行对应一键脚本，RCON 命令直接在此执行。'
    })
    $window.Add_Closed({
        $timer.Stop()
        if ($script:RconPS) { try { $script:RconPS.Dispose() } catch { } }
        if ($script:SizePS) { try { $script:SizePS.Dispose() } catch { } }
        if ($script:KitCheckPS) { try { $script:KitCheckPS.Stop() } catch { }; try { $script:KitCheckPS.Dispose() } catch { } }
        if ($script:GpuPS) { try { $script:GpuPS.Stop() } catch { }; try { $script:GpuPS.Dispose() } catch { } }
    })

    [void]$window.ShowDialog()
} catch {
    $message = "控制面板启动失败：`r`n" + $_.Exception.Message + "`r`n`r`n" + $_.ScriptStackTrace
    try {
        [void][System.Windows.MessageBox]::Show($message, '控制面板启动失败', 'OK', 'Error')
    } catch {
        Write-Host $message
    }
    exit 1
}
