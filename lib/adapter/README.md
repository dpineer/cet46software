# LM-Studio 适配器

## 概述

此适配器用于对接 LM-Studio 本地大语言模型服务，为四六级学习应用提供本地AI能力。

## 功能特性

1. **完整的LM-Studio API支持**
   - 聊天补全接口 (`/v1/chat/completions`)
   - 模型列表查询 (`/v1/models`)
   - 健康检查 (`/health`)
   - 流式响应支持
   - **图片输入支持**（多模态）

2. **与现有AiService完全兼容**
   - 单词详细解释（相同接口）
   - 流式错误分析（相同接口）
   - 文本翻译与作文批改（相同接口）
   - 填空段落生成（相同接口）
   - **图片分析**（新增功能）

3. **用户友好的设置界面**
   - 连接配置
   - 模型选择
   - 连接测试
   - 模型列表获取

## 使用方法

### 1. 安装LM-Studio

1. 访问 [LM-Studio官网](https://lmstudio.ai/)
2. 下载并安装适合您操作系统的版本
3. 启动LM-Studio并加载模型

### 2. 启动本地服务器

在LM-Studio中：
1. 选择要使用的模型
2. 点击"启动服务器"按钮
3. 确保服务器运行在 `localhost:1234`（默认端口）

### 3. 配置应用

1. 在应用中找到"LM-Studio设置"入口
2. 填写连接信息：
   - 主机地址：`localhost`
   - 端口：`1234`
   - 模型名称：选择或输入模型名称
   - API Key：如果需要认证
3. 点击"测试连接"验证配置
4. 点击"保存设置"

### 4. 使用AI功能

配置完成后，应用将自动使用LM-Studio服务：
- 单词学习时的AI解释
- 翻译与作文批改
- 图片分析（OCR和内容理解）
- 其他AI辅助功能

### 5. 使用图片输入功能

LM-Studio适配器支持多模态图片输入：

```dart
import 'adapter/lm_studio_adapter.dart';
import 'adapter/image_utils.dart';

// 1. 选择图片并转换为base64
final base64Image = await ImageUtils.pickImageAndConvertToBase64();
if (base64Image != null) {
  // 2. 分析图片中的英语学习内容
  final analysis = await LMStudioAiService.analyzeImageForLearning(base64Image);
  
  // 3. 或者提取图片中的文本
  final text = await LMStudioAiService.analyzeImageText(base64Image);
  
  // 4. 或者自定义分析
  final customAnalysis = await LMStudioAiService.analyzeImage(
    base64Image, 
    "请分析这张图片中的英语语法错误"
  );
}
```

### 6. 与现有OCR功能集成

LM-Studio的图片分析可以与现有的ML Kit OCR功能结合：

```dart
// 增强的OCR流程
final enhancedResult = await EnhancedOCRService.enhancedOCRWithLMStudio(imagePath);
```

## 文件结构

```
lib/adapter/
├── lm_studio_adapter.dart      # 核心适配器实现
├── lm_studio_settings.dart     # 设置界面
└── README.md                   # 本文档
```

## 核心类说明

### `LMStudioAdapter` (抽象接口)
- `request()`: 发送普通请求
- `streamRequest()`: 发送流式请求
- `getModels()`: 获取可用模型
- `isAvailable()`: 检查服务状态

### `LMStudioLocalAdapter` (具体实现)
- 支持自定义主机和端口
- 自动处理API Key认证
- 完整的错误处理

### `LMStudioAiService` (兼容层)
- 与现有`AiService`保持相同接口
- 自动切换DeepSeek和LM-Studio
- 统一的错误处理

### `AdapterFactory` (工厂类)
- 创建适配器实例
- 测试连接功能

### `LMStudioSettingsScreen` (设置界面)
- 用户友好的配置界面
- 实时连接测试
- 模型列表获取

## 集成到主程序

在主程序(`main.dart`)中添加：

```dart
// 导入适配器
import 'adapter/lm_studio_settings.dart';

// 在设置菜单中添加入口
ListTile(
  leading: Icon(Icons.settings),
  title: Text('LM-Studio 设置'),
  onTap: () => showLMStudioSettings(context),
),
```

## 故障排除

### 连接失败
1. 确保LM-Studio正在运行
2. 检查主机和端口配置
3. 验证防火墙设置
4. 尝试使用"获取模型"功能测试

### 模型不可用
1. 在LM-Studio中加载模型
2. 确保模型已下载完成
3. 检查模型名称是否正确

### 响应缓慢
1. 检查模型大小是否适合您的硬件
2. 考虑使用较小的模型
3. 调整生成参数（温度、最大令牌数）

## 注意事项

1. **性能考虑**：本地模型运行需要足够的RAM和VRAM
2. **模型选择**：选择适合您硬件的模型大小
3. **隐私优势**：所有数据在本地处理，无需网络传输
4. **离线使用**：配置完成后可完全离线使用

## 扩展开发

如需扩展功能，可修改以下部分：

1. **添加新API端点**：在`LMStudioAdapter`中添加新方法
2. **自定义提示词**：修改`LMStudioAiService`中的提示模板
3. **UI定制**：修改`LMStudioSettingsScreen`界面
4. **错误处理**：增强适配器的错误恢复机制