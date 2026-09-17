import AppKit
@main struct EquipmentImageTests {
    static func main() {
        func sample(_ file: String, _ rect: CGRect) -> [Double] {
            let image = NSImage(contentsOfFile: file)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            return EquipmentVision.feature(image.cropping(to: rect)!)!
        }
        for (index, pair) in [(CGRect(x:34,y:42,width:76,height:76),CGRect(x:55,y:89,width:78,height:78)),(CGRect(x:186,y:42,width:76,height:76),CGRect(x:206,y:89,width:78,height:78))].enumerated() {
            let (offRect,onRect) = pair
            let off = sample("tests/fixtures/equipment/off.png", offRect)
            let on = sample("tests/fixtures/equipment/on.png", onRect)
            let running = Array(repeating:on,count:3), stopped = [off]
            print("ring distance",EquipmentVision.distance(on,off),"icon distance",EquipmentVision.iconDistance(on,off))
            precondition(EquipmentVision.separable(running,stopped))
            precondition(EquipmentVision.classify(off,active:running,inactive:stopped) == false)
            precondition(EquipmentVision.classify(on,active:running,inactive:stopped) == true)
            let white = sample("tests/fixtures/equipment/on-white.png", CGRect(x: index == 0 ? 17 : 170, y: 41, width: 76, height: 76))
            print("white circle:", EquipmentVision.classify(white,active:running,inactive:stopped) as Any)
            precondition(EquipmentVision.classify(white,active:running,inactive:stopped) == true)
            var rotated = on
            var ring: [Int] = []
            for y in 9..<32 { for x in 0..<32 {
                let dx = (Double(x)-15.5)/16, dy = (Double(y)-15.5)/16
                let r = sqrt(dx*dx+dy*dy)
                if r >= 0.62 && r <= 1 { ring.append((y*32+x)*3) }
            } }
            for (i, dest) in ring.enumerated() {
                let source = ring[(i+ring.count/3) % ring.count]
                for channel in 0..<3 { rotated[dest+channel] = on[source+channel] }
            }
            precondition(EquipmentVision.classify(rotated,active:running,inactive:stopped) == true)
            var greenTop = off
            for y in 0..<9 { for x in 0..<32 { greenTop[(y*32+x)*3+1] = 1 } }
            precondition(EquipmentVision.classify(greenTop,active:running,inactive:stopped) == false)
            let blank = Array(repeating:0.0,count:3072)
            precondition(EquipmentVision.classify(blank,active:running,inactive:stopped) == nil)
        }
        print("PASS: supplied two module pairs, static off sample, fixed green top ignored, blank rejected")
    }
}
