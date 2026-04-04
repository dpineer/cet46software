# Linux 版本发布说明

## 构建信息

- **应用名称**: cet46software
- **构建时间**: 2026年3月19日 23:38
- **平台**: Linux x64
- **版本类型**: Release
- **文件路径**: build/linux/x64/release/bundle/cet46software
- **文件类型**: ELF 64-bit LSB pie executable
- **文件大小**: 24016 字节

## 构建过程

使用以下命令构建：

```bash
flutter build linux --release
```

构建成功，生成了可在 Linux 系统上运行的独立可执行文件。

## 应用信息

- **应用名称**: 四六级 AI 词汇学习应用
- **功能特色**:
  - 智能复习算法 (SM2算法)
  - AI 智能纠错 (集成 DeepSeek API)
  - 多模式练习 (中英互译、拼写练习等)
  - 收藏功能
  - 进阶练习
  - 主题切换
  - 离线词库

## 运行要求

- Linux 系统 (x86_64)
- GNU C Library (glibc) 3.2.0 或更高版本
- 支持 OpenGL 的图形环境

## 运行方式

在终端中执行以下命令运行应用：

```bash
./build/linux/x64/release/bundle/cet46software
```

## 目录结构

```
bundle/
├── cet46software (可执行文件)
├── data/
│   ├── flutter_assets/
│   │   ├── AssetManifest.json
│   │   ├── FontManifest.json
│   │   ├── NOTICES.Z
│   │   ├── fonts/
│   │   └── packages/
│   └── icudtl.dat
└── lib/
    └── libflutter_linux_gtk.so