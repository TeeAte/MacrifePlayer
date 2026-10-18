// Anime4KError.swift
// Macrife Player · Phase 5 Anime4K 错误类型

import Foundation

enum Anime4KError: LocalizedError {
    case deviceNotSupported
    case weightFileNotFound(String)
    case invalidWeightFormat(String)
    case pipelineCreationFailed(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotSupported:
            return "Metal 设备不支持 Anime4K 滤镜"
        case .weightFileNotFound(let file):
            return "Anime4K 权重文件未找到: \(file)"
        case .invalidWeightFormat(let msg):
            return "Anime4K 权重格式不合法: \(msg)"
        case .pipelineCreationFailed(let reason):
            return "Anime4K Metal 计算管线创建失败: \(reason)"
        case .executionFailed(let reason):
            return "Anime4K 执行处理失败: \(reason)"
        }
    }
}
