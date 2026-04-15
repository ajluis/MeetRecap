import Foundation
import AppKit
import PDFKit

enum ExportFormat: String, CaseIterable {
    case markdown = "Markdown"
    case plainText = "Plain Text"
    case pdf = "PDF"
    
    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .pdf: return "pdf"
        }
    }
    
    var utType: String {
        switch self {
        case .markdown: return "net.daringfireball.markdown"
        case .plainText: return "public.plain-text"
        case .pdf: return "com.adobe.pdf"
        }
    }
}

final class ExportManager {
    
    /// Export meeting to a file and return the data
    static func exportMeeting(
        title: String,
        date: Date,
        duration: TimeInterval,
        summary: String?,
        actionItems: [String],
        segments: [(text: String, startTime: TimeInterval, endTime: TimeInterval, speaker: String?)],
        format: ExportFormat
    ) -> Data {
        switch format {
        case .markdown:
            return generateMarkdown(
                title: title, date: date, duration: duration,
                summary: summary, actionItems: actionItems, segments: segments
            )
        case .plainText:
            return generatePlainText(
                title: title, date: date, duration: duration,
                summary: summary, actionItems: actionItems, segments: segments
            )
        case .pdf:
            return generatePDF(
                title: title, date: date, duration: duration,
                summary: summary, actionItems: actionItems, segments: segments
            )
        }
    }
    
    /// Generate plain text transcript
    static func generateTranscriptText(
        segments: [(text: String, startTime: TimeInterval, endTime: TimeInterval, speaker: String?)]
    ) -> String {
        var output = ""
        for segment in segments {
            let timestamp = formatTimestamp(segment.startTime)
            if let speaker = segment.speaker {
                output += "[\(timestamp)] \(speaker): \(segment.text)\n"
            } else {
                output += "[\(timestamp)] \(segment.text)\n"
            }
        }
        return output
    }
    
    // MARK: - Markdown Export
    
    private static func generateMarkdown(
        title: String,
        date: Date,
        duration: TimeInterval,
        summary: String?,
        actionItems: [String],
        segments: [(text: String, startTime: TimeInterval, endTime: TimeInterval, speaker: String?)]
    ) -> Data {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        
        let durationStr = formatDuration(duration)
        
        var md = """
        # \(title)
        
        **Date:** \(dateFormatter.string(from: date))  
        **Duration:** \(durationStr)
        
        """
        
        if let summary = summary {
            md += """
            ## Summary
            
            \(summary)
            
            """
        }
        
        if !actionItems.isEmpty {
            md += "## Action Items\n\n"
            for item in actionItems {
                md += "- [ ] \(item)\n"
            }
            md += "\n"
        }
        
        md += "## Transcript\n\n"
        
        for segment in segments {
            let timestamp = formatTimestamp(segment.startTime)
            if let speaker = segment.speaker {
                md += "**[\(timestamp)] \(speaker):** \(segment.text)\n\n"
            } else {
                md += "**[\(timestamp)]** \(segment.text)\n\n"
            }
        }
        
        return md.data(using: .utf8) ?? Data()
    }
    
    // MARK: - Plain Text Export
    
    private static func generatePlainText(
        title: String,
        date: Date,
        duration: TimeInterval,
        summary: String?,
        actionItems: [String],
        segments: [(text: String, startTime: TimeInterval, endTime: TimeInterval, speaker: String?)]
    ) -> Data {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        
        let durationStr = formatDuration(duration)
        let separator = String(repeating: "=", count: 50)
        
        var txt = """
        \(separator)
        \(title)
        \(separator)
        
        Date: \(dateFormatter.string(from: date))
        Duration: \(durationStr)
        
        """
        
        if let summary = summary {
            txt += """
            SUMMARY
            -------
            \(summary)
            
            """
        }
        
        if !actionItems.isEmpty {
            txt += "ACTION ITEMS\n"
            txt += "------------\n"
            for (i, item) in actionItems.enumerated() {
                txt += "\(i + 1). \(item)\n"
            }
            txt += "\n"
        }
        
        txt += "TRANSCRIPT\n"
        txt += "----------\n\n"
        
        for segment in segments {
            let timestamp = formatTimestamp(segment.startTime)
            if let speaker = segment.speaker {
                txt += "[\(timestamp)] \(speaker): \(segment.text)\n"
            } else {
                txt += "[\(timestamp)] \(segment.text)\n"
            }
        }
        
        return txt.data(using: .utf8) ?? Data()
    }
    
    // MARK: - PDF Export
    
    private static func generatePDF(
        title: String,
        date: Date,
        duration: TimeInterval,
        summary: String?,
        actionItems: [String],
        segments: [(text: String, startTime: TimeInterval, endTime: TimeInterval, speaker: String?)]
    ) -> Data {
        let pdfData = NSMutableData()
        
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        guard let pdfContext = CGContext(consumer: CGDataConsumer(data: pdfData as CFMutableData)!, mediaBox: &mediaBox, nil) else {
            return Data()
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        
        let titleFont = NSFont.boldSystemFont(ofSize: 18)
        let headerFont = NSFont.boldSystemFont(ofSize: 14)
        let bodyFont = NSFont.systemFont(ofSize: 11)
        let timestampFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        
        var yPosition: CGFloat = 740
        let leftMargin: CGFloat = 50
        let rightMargin: CGFloat = 562
        let lineHeight: CGFloat = 16
        let pageHeight: CGFloat = 792
        
        func startNewPage() {
            pdfContext.beginPage(mediaBox: &mediaBox)
            yPosition = 740
        }
        
        func checkPageBreak(needed: CGFloat = 20) {
            if yPosition - needed < 50 {
                pdfContext.endPage()
                startNewPage()
            }
        }
        
        func drawText(_ text: String, font: NSFont, x: CGFloat, y: CGFloat, maxWidth: CGFloat = 512) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let attributedString = NSAttributedString(string: text, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributedString)
            pdfContext.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, pdfContext)
        }
        
        startNewPage()
        
        // Title
        drawText(title, font: titleFont, x: leftMargin, y: yPosition)
        yPosition -= lineHeight * 2
        
        // Date and duration
        let durationStr = formatDuration(duration)
        drawText("Date: \(dateFormatter.string(from: date))", font: bodyFont, x: leftMargin, y: yPosition)
        yPosition -= lineHeight
        drawText("Duration: \(durationStr)", font: bodyFont, x: leftMargin, y: yPosition)
        yPosition -= lineHeight * 2
        
        // Summary
        if let summary = summary {
            checkPageBreak(needed: 60)
            drawText("Summary", font: headerFont, x: leftMargin, y: yPosition)
            yPosition -= lineHeight * 1.5
            
            drawText(summary, font: bodyFont, x: leftMargin, y: yPosition)
            yPosition -= lineHeight * 2
        }
        
        // Action Items
        if !actionItems.isEmpty {
            checkPageBreak(needed: 40)
            drawText("Action Items", font: headerFont, x: leftMargin, y: yPosition)
            yPosition -= lineHeight * 1.5
            
            for item in actionItems {
                checkPageBreak()
                drawText("• \(item)", font: bodyFont, x: leftMargin + 10, y: yPosition)
                yPosition -= lineHeight
            }
            yPosition -= lineHeight
        }
        
        // Transcript
        checkPageBreak(needed: 40)
        drawText("Transcript", font: headerFont, x: leftMargin, y: yPosition)
        yPosition -= lineHeight * 1.5
        
        for segment in segments {
            checkPageBreak(needed: 30)
            let timestamp = formatTimestamp(segment.startTime)
            
            if let speaker = segment.speaker {
                drawText("[\(timestamp)] \(speaker):", font: timestampFont, x: leftMargin, y: yPosition)
                yPosition -= lineHeight
                drawText(segment.text, font: bodyFont, x: leftMargin + 10, y: yPosition)
            } else {
                drawText("[\(timestamp)]", font: timestampFont, x: leftMargin, y: yPosition)
                yPosition -= lineHeight
                drawText(segment.text, font: bodyFont, x: leftMargin + 10, y: yPosition)
            }
            yPosition -= lineHeight * 1.5
        }
        
        pdfContext.endPage()
        pdfContext.closePDF()
        
        return pdfData as Data
    }
    
    // MARK: - Helpers
    
    private static func formatTimestamp(_ timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private static func formatDuration(_ timeInterval: TimeInterval) -> String {
        let hours = Int(timeInterval) / 3600
        let minutes = (Int(timeInterval) % 3600) / 60
        let seconds = Int(timeInterval) % 60
        
        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else {
            return String(format: "%dm %ds", minutes, seconds)
        }
    }
}
