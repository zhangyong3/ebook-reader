import AppKit
import Foundation
let output = CommandLine.arguments[1]
let size = NSSize(width:1024,height:1024)
let image = NSImage(size:size)
image.lockFocus()
NSColor(red:0.20,green:0.34,blue:0.27,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:40,y:40,width:944,height:944),xRadius:210,yRadius:210).fill()
let symbol = NSImage(systemSymbolName:"book.closed.fill",accessibilityDescription:nil)!.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[NSColor(red:0.96,green:0.95,blue:0.90,alpha:1)]))!
symbol.draw(in:NSRect(x:239,y:220,width:546,height:584))
image.unlockFocus()
let representation=NSBitmapImageRep(data:image.tiffRepresentation!)!
try representation.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output))
