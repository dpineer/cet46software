import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

// ==========================================
// 图片工具类
// ==========================================
class ImageUtils {
  static final ImagePicker _picker = ImagePicker();
  
  /// 从图库选择图片并转换为base64
  static Future<String?> pickImageAndConvertToBase64() async {
    try {
      final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
      if (image == null) return null;
      
      final file = File(image.path);
      final bytes = await file.readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      if (kDebugMode) {
        print('图片选择或转换失败: $e');
      }
      return null;
    }
  }
  
  /// 拍照并转换为base64
  static Future<String?> takePhotoAndConvertToBase64() async {
    try {
      final XFile? image = await _picker.pickImage(source: ImageSource.camera);
      if (image == null) return null;
      
      final file = File(image.path);
      final bytes = await file.readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      if (kDebugMode) {
        print('拍照或转换失败: $e');
      }
      return null;
    }
  }
  
  /// 将文件转换为base64
  static Future<String?> fileToBase64(File file) async {
    try {
      final bytes = await file.readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      if (kDebugMode) {
        print('文件转换失败: $e');
      }
      return null;
    }
  }
  
  /// 将base64字符串转换为Uint8List
  static Uint8List? base64ToUint8List(String base64String) {
    try {
      return base64Decode(base64String);
    } catch (e) {
      if (kDebugMode) {
        print('base64解码失败: $e');
      }
      return null;
    }
  }
  
  /// 获取图片的MIME类型
  static String getImageMimeType(String base64String) {
    try {
      // 检查base64字符串的前几个字节来确定图片类型
      final bytes = base64Decode(base64String.substring(0, 20));
      
      if (bytes.length >= 3) {
        if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
          return 'image/jpeg';
        }
        if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
          return 'image/png';
        }
        if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
          return 'image/gif';
        }
        if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
          return 'image/bmp';
        }
      }
    } catch (e) {
      // 忽略错误，返回默认值
    }
    
    return 'image/jpeg'; // 默认返回JPEG
  }
  
  /// 压缩base64图片（简单实现）
  static String compressBase64Image(String base64String, {int maxWidth = 1024, int maxHeight = 1024}) {
    // 注意：这是一个简化的实现，实际项目中可能需要使用图像处理库
    // 这里只是返回原始base64，实际应用中可以集成flutter_image_compress等库
    return base64String;
  }
  
  /// 检查base64字符串是否有效
  static bool isValidBase64Image(String base64String) {
    try {
      final bytes = base64Decode(base64String);
      return bytes.isNotEmpty;
    } catch (e) {
      return false;
    }
  }
  
  /// 获取图片大小（KB）
  static double getImageSizeInKB(String base64String) {
    try {
      final bytes = base64Decode(base64String);
      return bytes.length / 1024;
    } catch (e) {
      return 0;
    }
  }
}

// ==========================================
// 图片分析服务
// ==========================================
class ImageAnalysisService {
  /// 分析图片中的英语学习内容
  static Future<String> analyzeEnglishLearningImage(String base64Image) async {
    // 这里可以调用LM-Studio的图片分析功能
    // 实际实现中应该调用 LMStudioAiService.analyzeImageForLearning(base64Image)
    return "图片分析功能已就绪，请集成LM-Studio适配器以使用此功能。";
  }
  
  /// 提取图片中的文本
  static Future<String> extractTextFromImage(String base64Image) async {
    // 这里可以调用LM-Studio的OCR功能
    // 实际实现中应该调用 LMStudioAiService.analyzeImageText(base64Image)
    return "OCR功能已就绪，请集成LM-Studio适配器以使用此功能。";
  }
  
  /// 分析图片中的单词和句子
  static Future<Map<String, dynamic>> analyzeImageForVocabulary(String base64Image) async {
    // 分析图片中的英语单词和句子
    final analysis = await analyzeEnglishLearningImage(base64Image);
    
    return {
      'analysis': analysis,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'imageSizeKB': ImageUtils.getImageSizeInKB(base64Image),
    };
  }
}

// ==========================================
// 与现有OCR功能集成的示例
// ==========================================
class EnhancedOCRService {
  /// 增强的OCR功能：结合ML Kit和LM-Studio
  static Future<String> enhancedOCRWithLMStudio(String imagePath) async {
    try {
      // 1. 首先使用ML Kit进行基本OCR
      // 这里假设已经有ML Kit的OCR功能
      
      // 2. 将图片转换为base64
      final file = File(imagePath);
      final base64Image = await ImageUtils.fileToBase64(file);
      
      if (base64Image == null) {
        return "图片转换失败";
      }
      
      // 3. 使用LM-Studio进行增强分析
      // 这里可以调用 LMStudioAiService.analyzeImageForLearning(base64Image)
      
      return "增强OCR功能已就绪，请集成LM-Studio适配器以使用此功能。\n"
             "图片大小: ${ImageUtils.getImageSizeInKB(base64Image).toStringAsFixed(2)} KB";
    } catch (e) {
      return "增强OCR处理失败: $e";
    }
  }
}