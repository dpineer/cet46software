# 四六级 AI 词汇学习应用

一款基于 Flutter 开发的智能英语词汇学习应用，采用 SM2 算法进行间隔重复记忆，并集成 AI 助手提供个性化学习反馈。

## 功能特色

- **智能复习算法**：采用 SM2 算法，根据艾宾浩斯遗忘曲线科学安排复习计划
- **AI 智能纠错**：集成 DeepSeek API，提供错误分析、词源词根、记忆法等个性化反馈
- **多模式练习**：支持中英互译、拼写练习等多种学习模式
- **收藏功能**：可收藏重点单词，便于针对性复习
- **进阶练习**：AI 生成填空段落，提升词汇应用能力
- **主题切换**：支持亮色/暗色主题切换
- **离线词库**：内置四六级词汇数据库，支持离线学习

## 技术栈

- **Flutter**：跨平台 UI 框架
- **Dart**：应用开发语言
- **SQLite**：本地数据存储
- **Provider**：状态管理
- **Dio**：HTTP 客户端
- **Flutter Secure Storage**：安全存储 API 密钥
- **DeepSeek API**：AI 服务接口

## 项目结构

```
cet46software/
├── lib/
│   └── main.dart          # 主应用文件
├── assets/
│   └── cet_words.db       # 四六级词汇数据库
├── android/               # Android 原生配置
├── ios/                   # iOS 原生配置
├── pubspec.yaml           # 项目依赖配置
└── README.md              # 项目说明文档
```

## 安装与运行

### 环境要求

- Flutter SDK (>=3.0.0)
- Dart SDK (>=3.0.0)

### 安装步骤

1. 克隆项目：
   ```bash
   git clone <repository-url>
   cd cet46software
   ```

2. 安装依赖：
   ```bash
   flutter pub get
   ```

3. 运行应用：
   ```bash
   flutter run
   ```

## 使用说明

### 1. 配置 AI 密钥

首次使用前需要配置 DeepSeek API 密钥：

1. 访问 [DeepSeek](https://www.deepseek.com/) 获取 API 密钥
2. 在应用中进入"设置"页面
3. 输入 API 密钥并保存

### 2. 学习模式

- **开始今日任务**：根据复习计划学习到期的单词
- **继续学习**：继续未完成的学习任务
- **进阶练习**：AI 生成的填空段落练习

### 3. 练习类型

- **英译中**：根据英文单词选择中文释义
- **中译英**：根据中文释义选择英文单词
- **拼写练习**：根据释义拼写英文单词

### 4. AI 助手功能

当答错题目时，AI 助手会提供：

- 错误分析
- 词源词根解析
- 记忆法建议
- 例句展示

### 5. 收藏功能

在 AI 诊断弹窗中点击⭐可收藏单词，便于后续针对性复习。

## 核心功能实现

### SM2 算法

应用采用 SM2 算法（SuperMemo 2）进行间隔重复记忆，根据用户对单词的掌握程度动态调整复习间隔。

### 数据库设计

- **words 表**：存储词汇信息（拼写、释义、复习间隔、难度系数等）
- **favorites 表**：存储收藏的单词及 AI 解析信息

### AI 集成

通过 DeepSeek API 提供以下服务：

- 词汇详细解析
- 错误分析与纠正
- 例句生成
- 进阶练习内容生成

## 项目配置

### 依赖项

- `provider`: 状态管理
- `sqflite`: SQLite 数据库操作
- `dio`: HTTP 客户端
- `flutter_secure_storage`: 安全存储
- `shared_preferences`: 本地偏好设置
- `file_picker`: 文件选择器

### 资源文件

- `assets/cet_words.db`: 四六级词汇数据库文件

## 开发说明

### 状态管理

应用使用 Provider 进行状态管理，主要包含：

- `ThemeProvider`: 主题状态管理
- `LearningProvider`: 学习进度状态管理

### 数据模型

- `Word`: 词汇数据模型，包含 SM2 算法相关属性
- `FavoriteEntry`: 收藏条目数据模型

## 构建与发布

### Linux 版本

项目支持构建 Linux 桌面版本，使用以下命令构建：

```bash
flutter build linux --release
```

构建完成后，可执行文件位于 `build/linux/x64/release/bundle/cet46software`。

### Windows 和 macOS 版本

项目同样支持构建 Windows 和 macOS 版本：

- Windows: `flutter build windows --release`
- macOS: `flutter build macos --release`

## 贡献

欢迎提交 Issue 和 Pull Request 来改进本项目。

## 许可证

本项目采用 MIT 许可证。

## 致谢

- Flutter 团队
- DeepSeek API
- 开源社区
