import AppKit
import SwiftUI

/// Read-only native Markdown. No HTML, remote image fetches or embedded web scripts.
/// 代码块与行内代码按 02B·10 方案 A：行内代码只留 #EFEFEB 浅灰底；代码块整块 #F7F7F5、圆角 12，顶上一行语言和常显的「复制」。
struct NativeMarkdownView: View {
    private struct Block: Identifiable { let id:Int; let kind:String; let text:String; let rows:[[String]]; let level:Int; var language = "" }
    private let blocks:[Block]
    private let truncated:Bool
    /// 正文字号与行高；对话回复用 02B·03 的 13.5 / 24。
    private let size:CGFloat, line:CGFloat
    /// `softBreaks`：同 Web 岗位描述的 markdown-it `breaks: true`，相邻的普通文字行合成一段、段内换行，空行才分段。
    init(source:String, size:CGFloat=13, line:CGFloat=0, softBreaks:Bool=false) {
        self.size=size; self.line=line
        let limited=String(source.prefix(500_000)); let characterTruncated=limited.count<source.count
        let lines=limited.components(separatedBy:"\n"); var blocks:[Block]=[], index=0
        func cells(_ line:String)->[String] { var parts=line.split(separator:"|",omittingEmptySubsequences:false).map{String($0).trimmingCharacters(in:.whitespaces)};if parts.first=="" {parts.removeFirst()};if parts.last==""{parts.removeLast()};return Array(parts.prefix(20)) }
        while index<lines.count && blocks.count<5000 {
            let line=lines[index],trim=line.trimmingCharacters(in:.whitespaces)
            if trim.hasPrefix("```") {let language=String(trim.dropFirst(3)).trimmingCharacters(in:.whitespaces);var content:[String]=[];index+=1;while index<lines.count && !lines[index].trimmingCharacters(in:.whitespaces).hasPrefix("```"){content.append(lines[index]);index+=1};blocks.append(Block(id:blocks.count,kind:"code",text:content.joined(separator:"\n"),rows:[],level:language=="mermaid" ? 1:0,language:language));index+=1;continue}
            if index+1<lines.count,line.contains("|"),lines[index+1].contains("---") {var rows=[cells(line)];index+=2;while index<lines.count && lines[index].contains("|") && !lines[index].isEmpty {rows.append(cells(lines[index]));index+=1};blocks.append(Block(id:blocks.count,kind:"table",text:"",rows:rows,level:0));continue}
            let level=trim.prefix(while:{$0=="#"}).count
            let kind=level>0 && level<=6 && trim.dropFirst(level).hasPrefix(" ") ? "heading":trim.hasPrefix("![") ? "image":"text"
            let plain=kind=="text" && !trim.hasPrefix("- ")
            if softBreaks, plain, index>0, !lines[index-1].trimmingCharacters(in:.whitespaces).isEmpty, let last=blocks.last, last.kind=="text", !last.text.hasPrefix("• ") {
                blocks[blocks.count-1]=Block(id:last.id,kind:"text",text:last.text+"\n"+trim,rows:[],level:0)
            } else if !trim.isEmpty { blocks.append(Block(id:blocks.count,kind:kind,text:kind=="heading" ? String(trim.dropFirst(level+1)):trim.hasPrefix("- ") ? "• "+String(trim.dropFirst(2)):trim,rows:[],level:level)) }
            index+=1
        }
        self.blocks=blocks
        self.truncated=characterTruncated || index<lines.count
    }
    var body:some View {
        VStack(alignment:.leading,spacing:line > 0 ? 10 : 12) {
            if truncated { Text("正文较长，预览显示前 50 万字符；完整内容请下载原文件查看。").foregroundStyle(.orange).font(.system(size:12)) }
            ForEach(blocks){block in
                if block.kind=="heading" {Text(inline(block.text)).font(.system(size:max(14,25-Double(block.level)*2),weight:.semibold)).padding(.top,8)}
                else if block.kind=="code" {MarkdownCodeBlock(code:block.text,language:block.language,mermaid:block.level==1)}
                else if block.kind=="table" {ScrollView(.horizontal){Grid(alignment:.leading,horizontalSpacing:16,verticalSpacing:10){ForEach(Array(block.rows.enumerated()),id:\.offset){row,values in GridRow{ForEach(Array(values.enumerated()),id:\.offset){_,value in Text(inline(value)).font(.system(size:12,weight:row==0 ? .semibold:.regular)).frame(minWidth:80,maxWidth:280,alignment:.leading)}}}}.padding(12).overlay(RoundedRectangle(cornerRadius:8).stroke(Color(hex:0xE4E4E0)))}}
                else if block.kind=="image" {Label("文档图片请下载原文件查看",systemImage:"photo").font(.system(size:12)).foregroundStyle(.secondary)}
                else {Text(inline(block.text)).font(.system(size:size)).lineHeight(size, line > 0 ? line : size*1.2, .system).textSelection(.enabled)}
            }
        }
    }
    /// 行内 Markdown；行内代码换等宽字、#EFEFEB 底（方案 A 不加框）。
    private func inline(_ source:String)->AttributedString {
        var text=(try? AttributedString(markdown:source,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(size: max(11, size - 1), design: .monospaced)
            text[run.range].backgroundColor = Color(hex: 0xEFEFEB)
        }
        return text
    }
}

/// 代码块（02B·10 方案 A）：浅灰底无边框，页眉左语言、右常显「复制」。
private struct MarkdownCodeBlock: View {
    let code: String
    let language: String
    let mermaid: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text(mermaid ? "mermaid · 原生预览暂不执行图表脚本" : language.isEmpty ? "代码" : language)
                    .font(.system(size: 12)).foregroundStyle(Color(hex: 0x73726C)).lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                        Text(copied ? "已复制" : "复制").font(.system(size: 11.5))
                    }.foregroundStyle(Color(hex: 0x73726C)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(copied ? "已复制代码" : "复制代码")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12.5, design: .monospaced)).lineSpacing(5).foregroundStyle(Color(hex: 0x1D1D1B))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xF7F7F5), in: RoundedRectangle(cornerRadius: 12))
    }
}
