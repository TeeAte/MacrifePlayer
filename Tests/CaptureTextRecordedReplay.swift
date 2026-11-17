import Foundation
import CoreVideo
import QuartzCore
@main enum Main {
 static let w=1920,h=1080
 static func load(_ index:Int)throws->CVPixelBuffer {
  let data=try Data(contentsOf:URL(fileURLWithPath:"\(CommandLine.arguments.dropFirst().first ?? "output/capture-text-20261117/recorded-source")/source-\(index).nv12"));var b:CVPixelBuffer?
  CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,[kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&b)
  let pb=b!;CVPixelBufferLockBaseAddress(pb,[])
  data.withUnsafeBytes { raw in for plane in 0..<2 {
   let rows=plane==0 ? h:h/2,offset=plane==0 ? 0:w*h,stride=CVPixelBufferGetBytesPerRowOfPlane(pb,plane),out=CVPixelBufferGetBaseAddressOfPlane(pb,plane)!
   for y in 0..<rows {memcpy(out+y*stride,raw.baseAddress!+offset+y*w,w)}
  }};CVPixelBufferUnlockBaseAddress(pb,[]);return pb
 }
 static func luma(_ pb:CVPixelBuffer)->[UInt8] {
  CVPixelBufferLockBaseAddress(pb,.readOnly);defer{CVPixelBufferUnlockBaseAddress(pb,.readOnly)}
  let p=CVPixelBufferGetBaseAddressOfPlane(pb,0)!.assumingMemoryBound(to:UInt8.self),s=CVPixelBufferGetBytesPerRowOfPlane(pb,0)
  return (0..<h).flatMap{Array(UnsafeBufferPointer(start:p+$0*s,count:w))}
 }
 static func main()throws {
  let buffers=try (0..<16).map{try load($0)},source=buffers.map(luma)
  let detector=CaptureTextStabilizer();detector.observe(DecodedVideoFrame(pixelBuffer:buffers[0],pts:0))
  let deadline=CACurrentMediaTime()+5
  while detector.activeRegionCount==0 && CACurrentMediaTime()<deadline{Thread.sleep(forTimeInterval:0.01)}
  precondition(detector.activeRegionCount>0);print("Detected real-game regions",detector.activeRegionCount)
  var baseline:[[UInt8]]=[],after:[[UInt8]]=[]
  var baseTimes:[Double]=[],fixedTimes:[Double]=[]
  for fixed in [false,true] {
   let engine=AppleLowLatencyInterpolator()
   for i in 0..<16 {
    let f=DecodedVideoFrame(pixelBuffer:buffers[i],pts:Double(i)/30)
    let start=CACurrentMediaTime()
    let frames=engine.interpolate(f,sourceFPS:30,targetFPS:60,maxInferenceHeight:720,textStabilizer:fixed ? detector:nil)!
    if i>2 {if fixed{fixedTimes.append((CACurrentMediaTime()-start)*1000)}else{baseTimes.append((CACurrentMediaTime()-start)*1000)}}
    if i>0 {if fixed{after.append(luma(frames[0].pixelBuffer))}else{baseline.append(luma(frames[0].pixelBuffer))}}
   }
  }
  if CommandLine.arguments.contains("--timed") {
   let model=AppleLowLatencyInterpolator(),liveDetector=CaptureTextStabilizer()
   let fps=60.0,start=CACurrentMediaTime();var index=0,skipped=0;var times:[Double]=[]
   while index<180 {
    let deadline=start+Double(index)/fps,delay=deadline-CACurrentMediaTime()
    if delay>0 {Thread.sleep(forTimeInterval:delay)}
    let latest=Int((CACurrentMediaTime()-start)*fps)
    if latest>index+1 {skipped+=latest-index;index=latest}
    if index>=180 {break}
    let frame=DecodedVideoFrame(pixelBuffer:buffers[index%16],pts:Double(index)/fps)
    liveDetector.observe(frame)
    let begin=CACurrentMediaTime()
    _=model.interpolate(frame,sourceFPS:fps,targetFPS:fps*2,maxInferenceHeight:720,textStabilizer:liveDetector)
    if index>5 {times.append((CACurrentMediaTime()-begin)*1000)}
    index+=1
   }
   let sorted=times.sorted()
   print(String(format:"Timed buffered-input replay 60→120 (model stage only): p50 %.3fms p95 %.3fms max %.3fms; skipped %d input slots including startup",sorted[sorted.count/2],sorted[Int(Double(sorted.count-1)*0.95)],sorted.last!,skipped))
  }
  let areas=[("quest",1578,350,285,95),("controls",1600,822,250,130),("food",140,852,200,105),("clock",1430,70,140,40)]
  for (name,x,y,rw,rh) in areas {
   var old=0.0,new=0.0,n=0.0
   for i in 1..<16 {for yy in y..<(y+rh){for xx in x..<(x+rw){let k=yy*w+xx,a=Double(source[i-1][k]),b=Double(source[i][k]);
    guard min(a,b)>100,abs(a-b)<4 else{continue}
    var low=a
    for dy in -2...2{for dx in -2...2{low=min(low,Double(source[i-1][(yy+dy)*w+xx+dx]))}}
    guard a-low>28 else{continue}
    old+=abs(Double(baseline[i-1][k])-(a+b)*0.5);new+=abs(Double(after[i-1][k])-(a+b)*0.5);n+=1
   }}}
   print(String(format:"Real %@ static-stroke MAE %.3f → %.3f /255 (%d samples)",name,old/max(1,n),new/max(1,n),Int(n)))
  }
  print(String(format:"Apple720 real replay model: baseline mean %.3fms p95 %.3fms; text-stable mean %.3fms p95 %.3fms",baseTimes.reduce(0,+)/Double(baseTimes.count),baseTimes.sorted().last!,fixedTimes.reduce(0,+)/Double(fixedTimes.count),fixedTimes.sorted().last!))
 }
}
