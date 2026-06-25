import SwiftUI

struct RoundedCorners: Shape {
    var tl: CGFloat = 0
    var tr: CGFloat = 0
    var bl: CGFloat = 0
    var br: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let path = NSBezierPath()
        
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.curve(to: CGPoint(x: rect.maxX, y: rect.minY + tr),
                   controlPoint1: CGPoint(x: rect.maxX, y: rect.minY),
                   controlPoint2: CGPoint(x: rect.maxX, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.curve(to: CGPoint(x: rect.maxX - br, y: rect.maxY),
                   controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY),
                   controlPoint2: CGPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.curve(to: CGPoint(x: rect.minX, y: rect.maxY - bl),
                   controlPoint1: CGPoint(x: rect.minX, y: rect.maxY),
                   controlPoint2: CGPoint(x: rect.minX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.curve(to: CGPoint(x: rect.minX + tl, y: rect.minY),
                   controlPoint1: CGPoint(x: rect.minX, y: rect.minY),
                   controlPoint2: CGPoint(x: rect.minX, y: rect.minY))
        
        return Path(path.cgPath)
    }
}