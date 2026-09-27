# -*- coding: utf-8 -*-
"""v1.0.134 静态方法调用点核对 —— 精确版。

★ 只有一件事要抓：**「某个类型名.方法名」里，那个类型名在本工程根本不存在**。
  run #134 就挂在这：我写 `M3U8.sanitizeURLString(...)`，而本工程没这个类型
  （真名 `M3U8Playlist`）→ `error: cannot find 'M3U8' in scope`。
  括号配平查不出这种错，光靠"新代码写好了"的自检也查不出（我自检里写的是
  字符串匹配，压根没断言类型名对不对）。

做法（刻意收窄，避免 Self./UUID./Foundation 那些海量误报）：
  1. 收集本工程**自定义**类型名（struct/enum/class/actor/protocol/extension）—— 这才是"可能拼错"的源头；
     系统类型不收集（它拼错了编译器会告诉你，而且列举不全反而制造噪音）。
  2. 扫描代码里所有 `Ident.method(` 调用（**只看带括号的调用**，不看属性访问）。
  3. 只报告：`Ident` 首字母大写、**不在自定义类型集合里**、**也不在任何已知系统前缀集合里**、
     且 **在别处出现过 `Ident.` 前缀**（说明作者把它当类型用，不是局部变量）。
  4. 系统前缀集合用一个"见过就放过"的宽名单 —— 但**关键**：这个名单里**不能**有
     本工程自定义的类型名，否则会把拼错的放过去。
"""
import io, os, re, sys

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')

def read(p):
    with io.open(p, 'r', encoding='utf-8') as f:
        return f.read()

def strip(src):
    out, i, n, in_block = [], 0, len(src), False
    while i < n:
        if in_block:
            if src.startswith('*/', i): in_block = False; i += 2
            else: i += 1
            continue
        if src.startswith('/*', i): in_block = True; i += 2; continue
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j; continue
        if src.startswith('#"', i):
            j = src.find('"#', i + 2); i = n if j < 0 else j + 2; continue
        if src[i] == '"':
            i += 1
            while i < n:
                if src[i] == '\\': i += 2; continue
                if src[i] == '"': i += 1; break
                i += 1
            out.append('""'); continue
        out.append(src[i]); i += 1
    return ''.join(out)

# ── 1. 本工程自定义类型 ──
OWN = set()
DECL = re.compile(r'^\s*(?:public |internal |private |fileprivate |final |open |@\w+\s*)*'
                  r'(struct|enum|class|actor|protocol)\s+([A-Za-z_]\w*)', re.M)
for n in sorted(os.listdir(APP)):
    if n.endswith('.swift'):
        for m in DECL.finditer(read(os.path.join(APP, n))):
            OWN.add(m.group(2))
# extension Foo {  里的 Foo 也算"存在"（不然扩展系统类型会被误报）
for n in sorted(os.listdir(APP)):
    if not n.endswith('.swift'): continue
    for m in re.finditer(r'^\s*extension\s+([A-Za-z_]\w*)', read(os.path.join(APP, n)), re.M):
        OWN.add(m.group(1))

# ── 2. 允许出现的「系统/第三方」前缀 ──
# 只放**一定不是本工程自定义名字**的。注意：绝不能把 M3U8 之类的名字放进来。
SYS = set("""
Foundation UIKit SwiftUI AVFoundation AVKit WebKit Combine Photos MediaPlayer
CoreMedia QuartzCore CoreGraphics Network Security CryptoKit SafariServices
UniformTypeIdentifiers QuickLook CoreSpotlight
URL URLComponents URLRequest URLSession URLQueryItem URLCredential URLCredentialStorage
URLProtectionSpace URLError URLFileProtection URLResourceKey
Data String Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float Bool
Character Substring Array Dictionary Set Optional Result Range ClosedRange
Date DateFormatter ISO8601DateFormatter DateComponents Calendar TimeZone Locale
JSONEncoder JSONDecoder JSONSerialization PropertyListEncoder PropertyListDecoder
FileManager FileHandle FileAttributeKey FileProtectionType ProcessInfo
UserDefaults Bundle NotificationCenter Notification
DispatchQueue DispatchTime DispatchGroup DispatchSemaphore DispatchWorkItem
Thread RunLoop Timer Operation OperationQueue BlockOperation
Double CGFloat CGSize CGRect CGPoint CGAffineTransform CGColor CGImage CGContext
CGDataProvider CGImageAlphaInfo CGBitmapInfo UIGraphicsImageRenderer
UIGraphicsImageRendererFormat UIGraphicsBeginImageContext UIGraphicsGetImageFromCurrentImageContext
NSLock NSCondition NSRecursiveLock NSOperationQueue NSOperation
NSObject NSError NSRange NSAttributedString NSMutableAttributedString
NSPredicate NSSortDescriptor NSUUID NSString NSNumber NSArray NSDictionary NSData
NSCache NSCoding NSSecureCoding NSSet NSValue NSIndexPath NSHTTPURLResponse
UUID CharacterSet IndexSet BinaryInteger Numeric FloatingPoint Comparable Equatable
Hashable Codable Encodable Decodable CustomStringConvertible
Text Image Button Label Link Menu Toggle Slider Picker Stepper DatePicker ColorPicker
List ScrollView VStack HStack ZStack Spacer Divider Form Section Group ForEach
ScrollViewReader LazyVStack LazyHStack LazyVGrid LazyHGrid Grid GridRow
NavigationView NavigationLink NavigationStack NavigationSplitView
GeometryReader Canvas Path Circle Ellipse Rectangle Capsule RoundedRectangle
AngularGradient LinearGradient RadialGradient Material Color Gradient
ProgressView SecureField TextField TextEditor AnyView EmptyView TupleView
Animation Transition AnyTransition EdgeInsets Alignment HorizontalAlignment
VerticalAlignment Font FontWeight FontDesign ImageRenderer
ViewBuilder ViewModifier ShapeStyle ButtonStyle ToggleStyle LabelStyle ProgressViewStyle
Environment EnvironmentObject ObservedObject StateObject State Binding Published
AppStorage ScenePhase UIApplication
UIColor UIFont UIImage UIImageView UIView UIViewController UINavigationController
UITabBarController UIScreen UIDevice UIPasteboard UIMenu UIAction UIGestureRecognizer
UIPanGestureRecognizer UITapGestureRecognizer UILongPressGestureRecognizer
UIPinchGestureRecognizer UISwipeGestureRecognizer UIHoverGestureRecognizer
UIAlertController UIAlertAction UIStackView UILabel UIButton UIScrollView UITextField
UITableView UICollectionView UIActivityViewController UIDocumentPickerViewController
UIWindow UIWindowScene UIScene UISceneConfiguration UIViewControllerBasedStatusBarAppearance
UIApplicationDelegate UIApplicationLaunchOptionsKey UIScreenEdgePanGestureRecognizer
UIContextMenuInteraction UIDocument UITraitCollection UIUserInterfaceStyle
UIBarButtonItem UIImagePickerController UIVisualEffect UIBlurEffect
UIViewPropertyAnimator UIViewAnimationCurve UIScrollViewDelegate
AVPlayer AVPlayerItem AVURLAsset AVAsset AVAssetResourceLoader AVPlayerViewController
AVPictureInPictureController AVPlayerLayer AVAudioSession AVAudioEngine
AVContentKeySession AVAssetResourceLoadingRequest AVMutableComposition
AVAssetExportSession AVMediaType AVFileType AVError AVMetadataItem
WKWebView WKWebViewConfiguration WKUserScript WKUserContentController
WKWebsiteDataStore WKHTTPCookieStore WKPreferences WKWebpagePreferences
WKContentWorld WKContentRuleList WKContentRuleListStore WKNavigationAction
WKNavigationResponse WKNavigation WKBackForwardListItem WKScriptMessage
WKScriptMessageHandler WKDownload WKDownloadDelegate WKError WKFrameInfo
WKUIDelegate WKNavigationDelegate WKScriptMessageHandlerWithReply
PHPhotoLibrary PHAssetCreationRequest PHAsset PHPhotoLibraryCreationRequest
PHAuthorizationStatus UIImageWriteToSavedPhotosAlbum
CMMediaType CMSampleBuffer CVPixelBuffer CVPixelBufferPool
CFString CFURL CFData CFDictionary CFStringEncoding CFStringEncodings
CFAbsoluteTimeGetCurrent CFGetTypeID CFRelease CFRetain
UTType NSItemProvider NSItemProviderReading NSItemProviderWriting
UIDragInteraction UIDropInteraction UIDragItem NSUserActivity
PDFDocument PDFPage PDFView UIDocumentInteractionController
ByteCountFormatter NumberFormatter PersonNameComponentsFormatter
StringTransform StringProtocol LosslessStringConvertible
Mirror MemoryLayout ManagedBuffer UnsafePointer UnsafeMutablePointer
simd CrossPlatform
ImageIO CGImageDestination CGImageSource
UISegmentedControl UISwitch UISlider UIActivityIndicatorView
UITableViewController UITextView UISearchBar UINavigationBar UIToolbar
UIResponder NSLayoutConstraint NSLayoutAnchor NSLayoutXAxisAnchor
NSTextAttachment NSMutableParagraphStyle NSParagraphStyle
Animatable AnimatableData VectorArithmetic
PreferenceKey Layout Subview
Self Task
""".split())
# ── 关键：系统名单里绝不能混进本工程自定义类型名 —— 混了就等于把拼错的放过去 ──
overlap = SYS & OWN
if overlap:
    print('!! 白名单里混进了本工程类型名（会让拼错的蒙混过关）:', sorted(overlap))
    sys.exit(3)

print('本工程自定义类型 %d 个' % len(OWN))

# ── 3. 找 `Ident.method(` 调用 ──
CALL = re.compile(r'\b([A-Z][A-Za-z0-9_]*)\.([a-z][A-Za-z0-9_]*)\s*\(')
BAD = []
for n in sorted(os.listdir(APP)):
    if not n.endswith('.swift'): continue
    src = strip(read(os.path.join(APP, n)))
    for lineno, line in enumerate(src.split('\n'), 1):
        for m in CALL.finditer(line):
            name = m.group(1)
            if name in OWN or name in SYS: continue
            BAD.append((n, lineno, name, m.group(2), line.strip()[:110]))

if BAD:
    print('未识别的类型前缀（本工程没定义、也不在系统名单里）:')
    seen = set()
    for n, l, name, meth, line in BAD:
        k = (n, name)
        if k in seen: continue
        seen.add(k)
        print('  %s:%d  %s.%s(...)   %s' % (n, l, name, meth, line))
    print('\nRESULT: %d 处可疑（去重后 %d）' % (len(BAD), len(seen)))
    sys.exit(1)
print('RESULT: 所有「类型.方法(」调用的前缀都能对上 —— OK')
