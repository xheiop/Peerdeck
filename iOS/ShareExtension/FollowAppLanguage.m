#import <Foundation/Foundation.h>

// 分享扩展的界面语言跟随 app 设置里选的语言（app 把选择写在 App Group 的 language 键里，见 AppLanguage.swift）。
//
// 系统启动扩展时会带上 `-AppleLanguages (宿主或系统的语言)` 启动参数，参数域优先级最高，
// 所以写扩展自己的偏好域没用，只能改参数域；而且必须赶在第一次查本地化字符串之前，
// 主 bundle 选定语言后就缓存了（在 ShareViewController 的 init 里改已经晚了：界面还是英文，复数规则却变成中文的）。
// constructor 在 NSExtensionMain 之前运行，这时还没有任何本地化查询。
// 没有 App Group（未签名安装）或者选的是跟随系统（空字符串）时什么都不做。
__attribute__((constructor)) static void PDFollowAppLanguage(void) {
    @autoreleasepool {
        NSString *lang = [[[NSUserDefaults alloc] initWithSuiteName:@"group.dev.peerdeck"] stringForKey:@"language"];
        if (lang.length == 0) return;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *args = [[defaults volatileDomainForName:NSArgumentDomain] mutableCopy] ?: [NSMutableDictionary dictionary];
        args[@"AppleLanguages"] = @[lang];
        [defaults removeVolatileDomainForName:NSArgumentDomain];
        [defaults setVolatileDomain:args forName:NSArgumentDomain];
    }
}
