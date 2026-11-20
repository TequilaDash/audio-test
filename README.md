# audio-test

音频通路测试 App（相当于录音机），用于在 zContainer 容器里验证访客进程的声音**输入**与**输出**。

## 能力
- **输入**：录音（AVAudioRecorder，44.1kHz/单声道/AAC），实时电平表（peak dBFS）
- **输出**：播放刚录的文件、播放系统提示音（验证输出通路是否可用）
- **诊断信息**：当前 AVAudioSession 的 category/mode、输入/输出端口路由、最近一次错误

## 为什么需要它
容器里的访客进程能否拿到麦克风、能否把声音播出来，取决于：
- 扩展进程是否有前台 scene（决定 AVAudioSession 能否激活）
- 麦克风 TCC 权限是否落在**扩展进程自己的**权限记录上（宿主代答无效）
- 宿主代答激活 session 会打断后台正在播放的 App

用本 App 可以直接区分这几种情况：电平不动 = 输入没通；提示音不出 = 输出没通。

## 构建
GitHub Actions 自动出 IPA（`.github/workflows/build.yml`），nightly release 里下载 `AudioTest.ipa`。
本地产物：`xcodebuild archive -archivePath archive -scheme AudioTest -project AudioTest.xcodeproj -sdk iphoneos -arch arm64 -configuration Release`

装入 zContainer：把 IPA 导入 zContainer，签名后以访客方式启动（多任务窗口或全屏皆可）。
