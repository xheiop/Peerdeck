import SwiftUI

/// TMDB 要求的署名：官方 logo（不能比 app 自己的标识显眼，颜色和比例不能改）加一句声明。
/// logo 是 themoviedb.org/about/logos-attribution 的 blue_short.svg，只把 CSS 的 class 改成了路径上的 fill 属性
struct TMDBAttribution: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image("TMDBLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 10)
                .accessibilityLabel(Text(verbatim: "TMDB"))
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
        }
    }
}
