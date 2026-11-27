using System.Text.Json.Nodes;

namespace DrawOffer.Core.Models;

/// <summary>按 Mac MockReview 转成统一复盘结构；本地仅解释报告，不重新评分。</summary>
public static class MockReview
{
    public static readonly Dictionary<string, string> DimensionLabels = new(MockInterview.Dimensions)
    {
        ["structured_thinking"] = "结构化思考", ["analysis"] = "分析判断", ["planning"] = "计划组织协调", ["resilience"] = "应变与抗压", ["collaboration"] = "协作与影响", ["learning"] = "学习能力", ["professionalism"] = "职业素养"
    };
}
