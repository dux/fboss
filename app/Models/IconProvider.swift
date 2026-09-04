import AppKit

/// Provides vscode-icons SVG icons for known file types,
/// falling back to macOS system icons for unrecognized ones.
@MainActor
final class IconProvider {
    static let shared = IconProvider()

    private var cache: [String: NSImage] = [:]

    private init() {}

    // MARK: - Extension to icon name mapping

    private static let extMap: [String: String] = [
        // Programming
        "swift": "swift",
        "rs": "rust",
        "go": "go",
        "py": "python",
        "pyc": "python",
        "rb": "ruby",
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "jsx": "javascript-react",
        "ts": "typescript",
        "mts": "typescript",
        "cts": "typescript",
        "tsx": "typescript-react",
        "c": "c",
        "h": "c",
        "cpp": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "hxx": "cpp",
        "java": "java",
        "kt": "kotlin",
        "kts": "kotlin",
        "scala": "scala",
        "dart": "dart",
        "lua": "lua",
        "ex": "elixir",
        "exs": "elixir",
        "erl": "erlang",
        "hs": "haskell",
        "lhs": "haskell",
        "ml": "ocaml",
        "mli": "ocaml",
        "nim": "nim",
        "pl": "perl",
        "pm": "perl",
        "php": "php",
        "groovy": "groovy",
        "gradle": "groovy",
        "cs": "csharp",
        "csproj": "csharp",
        "fs": "fsharp",
        "fsx": "fsharp",
        "fsproj": "fsharp",
        "r": "r",
        "vb": "vb",
        "vbproj": "vb",
        "nix": "nix",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "fish": "bash",
        "bat": "batch",
        "cmd": "batch",
        "ps1": "powershell",
        "psm1": "powershell",

        // Web / Markup / Style
        "html": "html",
        "htm": "html",
        "css": "css",
        "scss": "sass",
        "sass": "sass",
        "less": "less",
        "svg": "svg",
        "graphql": "graphql",
        "gql": "graphql",
        "vue": "vue",
        "fez": "html",
        "postcss": "postcss",

        // Data / Config
        "json": "json",
        "jsonc": "json",
        "json5": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "toml",
        "xml": "xml",
        "plist": "xml",
        "csv": "csv",
        "tsv": "csv",
        "ini": "config",
        "cfg": "config",
        "conf": "config",
        "env": "env",
        "properties": "properties",
        "proto": "proto",
        "lock": "lock",
        "tex": "latex",
        "bib": "latex",

        // Documents
        "md": "markdown",
        "mdx": "markdown",
        "txt": "text",
        "rtf": "text",
        "pdf": "pdf",
        "doc": "ms-word",
        "docx": "ms-word",
        "xls": "ms-excel",
        "xlsx": "ms-excel",
        "ppt": "ms-powerpoint",
        "pptx": "ms-powerpoint",
        "org": "text",

        // Images
        "jpg": "image",
        "jpeg": "image",
        "png": "image",
        "gif": "image",
        "bmp": "image",
        "webp": "image",
        "heic": "image",
        "heif": "image",
        "tiff": "image",
        "tif": "image",
        "ico": "image",
        "avif": "image",

        // Audio / Video
        "mp3": "audio",
        "wav": "audio",
        "flac": "audio",
        "aac": "audio",
        "ogg": "audio",
        "wma": "audio",
        "m4a": "audio",
        "mp4": "video",
        "mov": "video",
        "avi": "video",
        "mkv": "video",
        "wmv": "video",
        "flv": "video",
        "webm": "video",
        "m4v": "video",

        // Archives
        "zip": "zip",
        "tar": "zip",
        "gz": "zip",
        "bz2": "zip",
        "xz": "zip",
        "7z": "zip",
        "rar": "zip",
        "tgz": "zip",
        "zst": "zip",
        "dmg": "zip",

        // Installer packages
        "pkg": "package",
        "mpkg": "package",
        "xip": "package",

        // Internet locations
        "webloc": "link",

        // Fonts
        "ttf": "font",
        "otf": "font",
        "woff": "font",
        "woff2": "font",
        "eot": "font",

        // Database
        "sql": "database",
        "sqlite": "database",
        "db": "database",

        // Binary / Executables
        "exe": "exe",
        "dll": "binary",
        "so": "binary",
        "dylib": "binary",
        "o": "binary",
        "a": "binary",
        "wasm": "binary",

        // Keys / Certs
        "pem": "key",
        "crt": "certificate",
        "cer": "certificate",
        "p12": "key",
        "pfx": "key",
        "pub": "key",

        // Diff / Patch
        "diff": "diff",
        "patch": "diff",

        // Makefile handled by filename
        "cmake": "cmake",

        // Docker
        "dockerignore": "docker",

        // Git
        "gitignore": "git",
        "gitattributes": "git",
        "gitmodules": "git",

        // Log
        "log": "log"
    ]

    // Filename (lowercase) to icon name
    private static let nameMap: [String: String] = [
        "makefile": "makefile",
        "cmakelists.txt": "cmake",
        "dockerfile": "docker",
        "docker-compose.yml": "docker-compose",
        "docker-compose.yaml": "docker-compose",
        "compose.yml": "docker-compose",
        "compose.yaml": "docker-compose",
        ".gitignore": "git",
        ".gitattributes": "git",
        ".gitmodules": "git",
        ".env": "env",
        ".env.local": "env",
        ".env.development": "env",
        ".env.production": "env",
        "package.json": "npm",
        "package-lock.json": "npm",
        "yarn.lock": "yarn-lock",
        "pnpm-lock.yaml": "pnpm",
        "gemfile": "ruby",
        "gemfile.lock": "ruby",
        "rakefile": "ruby",
        "hammerfile": "ruby",
        "cargo.toml": "rust",
        "cargo.lock": "rust",
        "go.mod": "go-mod",
        "go.sum": "go-mod",
        "license": "license",
        "license.md": "license",
        "license.txt": "license",
        "licence": "license",
        "copying": "license",
        "changelog": "todo",
        "changelog.md": "todo",
        "todo": "todo",
        "todo.md": "todo",
        ".eslintrc": "eslint",
        ".eslintrc.json": "eslint",
        "eslint.config.js": "eslint",
        "eslint.config.mjs": "eslint",
        "eslint.config.ts": "eslint",
        ".prettierrc": "prettier",
        ".prettierrc.json": "prettier",
        "prettier.config.js": "prettier",
        "prettier.config.mjs": "prettier",
        ".editorconfig": "editorconfig",
        "tsconfig.json": "tsconfig",
        "tailwind.config.js": "tailwind",
        "tailwind.config.ts": "tailwind",
        "postcss.config.js": "postcss",
        "postcss.config.mjs": "postcss",
        "vite.config.ts": "vite",
        "vite.config.js": "vite",
        "prisma": "prisma"
    ]

    // MARK: - Public API

    /// Returns an NSImage for the given file URL.
    func icon(for url: URL, isDirectory: Bool) -> NSImage {
        if isDirectory {
            return folderIcon(for: url)
        }
        return fileIcon(for: url)
    }

    static func resourceName(for url: URL, isDirectory: Bool) -> String? {
        if isDirectory {
            let ext = url.pathExtension.lowercased()
            guard ext != "app" else {
                return nil
            }
            // A bundle .mpkg is a package, not a folder the user browses.
            if FileExtensions.installerPackages.contains(ext) {
                return "package"
            }
            return folderMap[url.lastPathComponent.lowercased()] ?? "_folder"
        }

        let filename = url.lastPathComponent.lowercased()
        if let iconName = nameMap[filename] {
            return iconName
        }
        return extMap[url.pathExtension.lowercased()] ?? "_file"
    }

    // MARK: - Folder name -> specialized SVG mapping

    private static let folderMap: [String: String] = [
        "api": "folder_api",
        "app": "folder_app",
        "apps": "folder_app",
        "assets": "folder_assets",
        "audio": "folder_audio",
        "music": "folder_audio",
        "sounds": "folder_audio",
        "client": "folder_client",
        "frontend": "folder_client",
        "components": "folder_components",
        "config": "folder_config",
        ".config": "folder_config",
        "configuration": "folder_config",
        "core": "folder_core",
        "database": "folder_database",
        "db": "folder_database",
        "dist": "folder_dist",
        "build": "folder_dist",
        "out": "folder_dist",
        "output": "folder_dist",
        ".docker": "folder_docker",
        "docker": "folder_docker",
        "docs": "folder_docs",
        "doc": "folder_docs",
        "documentation": "folder_docs",
        "downloads": "folder_download",
        "fonts": "folder_fonts",
        "font": "folder_fonts",
        ".git": "folder_git",
        ".github": "folder_github",
        "hooks": "folder_hooks",
        "images": "folder_images",
        "img": "folder_images",
        "icons": "folder_images",
        "pictures": "folder_images",
        "photos": "folder_images",
        "lib": "folder_lib",
        "libs": "folder_lib",
        "library": "folder_lib",
        "vendor": "folder_lib",
        "middleware": "folder_middleware",
        "node_modules": "folder_node",
        "packages": "folder_packages",
        "plugins": "folder_plugins",
        "extensions": "folder_plugins",
        "addons": "folder_plugins",
        "public": "folder_public",
        "www": "folder_public",
        "static": "folder_public",
        "routes": "folder_routes",
        "scripts": "folder_scripts",
        "bin": "folder_scripts",
        "server": "folder_server",
        "backend": "folder_server",
        "shared": "folder_shared",
        "common": "folder_shared",
        "src": "folder_src",
        "source": "folder_src",
        "styles": "folder_styles",
        "css": "folder_styles",
        "scss": "folder_styles",
        "temp": "folder_temp",
        "tmp": "folder_temp",
        ".tmp": "folder_temp",
        "cache": "folder_temp",
        ".cache": "folder_temp",
        "templates": "folder_templates",
        "layouts": "folder_templates",
        "tests": "folder_tests",
        "test": "folder_tests",
        "spec": "folder_tests",
        "__tests__": "folder_tests",
        "types": "folder_types",
        "typings": "folder_types",
        "utils": "folder_utils",
        "helpers": "folder_utils",
        "tools": "folder_utils",
        "upload": "folder_upload",
        "uploads": "folder_upload",
        "video": "folder_video",
        "videos": "folder_video",
        "movies": "folder_video",
        "views": "folder_views",
        "pages": "folder_views",
        ".vscode": "folder_vscode"
    ]

    private func folderIcon(for url: URL) -> NSImage {
        // .app bundles should show their actual application icon
        if url.pathExtension.lowercased() == "app" {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            return icon
        }

        if let iconName = Self.resourceName(for: url, isDirectory: true),
           let img = loadSVG(iconName) {
            return img
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func fileIcon(for url: URL) -> NSImage {
        if let iconName = Self.resourceName(for: url, isDirectory: false),
           let img = loadSVG(iconName) {
            return img
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - SVG Loading

    private func loadSVG(_ name: String) -> NSImage? {
        if let cached = cache[name] {
            return cached
        }

        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons") else {
            return nil
        }

        guard let data = try? Data(contentsOf: url),
              let nsImage = NSImage(data: data) else {
            return nil
        }

        nsImage.size = NSSize(width: 16, height: 16)
        cache[name] = nsImage
        return nsImage
    }

}
