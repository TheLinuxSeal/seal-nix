import io.github.thelinuxseal.seal.check.Diagnostic;
import io.github.thelinuxseal.seal.embed.SealEngine;
import io.github.thelinuxseal.seal.embed.SealException;
import io.github.thelinuxseal.seal.embed.SealScript;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.stream.Stream;

/**
 * SealNix's host: turns a NixOS configuration written in Seal into a NixOS module.
 *
 * <pre>
 *   sealnix-host RUNTIME SPEC SRC...    the module on standard output; the program's own output on standard error
 * </pre>
 *
 * SPEC is what nix/spec.nix found the configuration's .seal files use: the NixOS options they name,
 * with each option's type, and the nixpkgs packages. From it the host writes the Seal classes
 * sealnix.Config and sealnix.Packages, for those alone, compiles them with RUNTIME's library and the
 * configuration (Seal's embed API), runs its entry's main() (the spec's "main" class, Main unless
 * it says), and then sealnix.Dump, which reports every value.
 *
 * Seal can't tell an option the program assigned from one it left alone, so the host does all of
 * this twice, with each option starting at another value the second time: false then true, 0 then 1,
 * "" then something else. An option that ends the same both times is one the program set, and is
 * what the module holds.
 */
public final class SealNix {

    public static void main(String[] args) throws IOException {
        if (args.length < 3) {
            System.err.println("usage: sealnix-host RUNTIME SPEC SRC...");
            System.exit(2);
        }
        Map<String, Object> spec = Json.object(new Json(Files.readString(Path.of(args[1]))).value());
        Map<String, String> fixed = new TreeMap<>();
        readSeal(Path.of(args[0]), fixed);
        Map<String, String> program = new TreeMap<>();
        for (int i = 2; i < args.length; i++) {
            readSeal(Path.of(args[i]), program);
        }
        try {
            Map<String, String> first = run(sources(spec, 0, fixed, program), true, spec);
            Map<String, String> second = run(sources(spec, 1, fixed, program), false, spec);
            Node root = new Node();
            first.forEach((path, nix) -> {
                if (nix.equals(second.get(path))) {
                    root.put(List.of(path.split("\u001f")), nix);
                }
            });
            System.out.print(module(root, program.keySet()));
        } catch (Failed f) {
            System.exit(1);
        }
    }

    /** Thrown once the reason has been printed. */
    static final class Failed extends RuntimeException {
    }

    static void readSeal(Path root, Map<String, String> into) throws IOException {
        try (Stream<Path> files = Files.walk(root)) {
            for (Path f : files.filter(p -> p.toString().endsWith(".seal")).sorted().toList()) {
                into.put(root.relativize(f).toString().replace('\\', '/'), Files.readString(f));
            }
        }
    }

    static Map<String, String> sources(Map<String, Object> spec, int seed, Map<String, String> fixed,
            Map<String, String> program) {
        Map<String, String> all = new TreeMap<>(fixed);
        Gen gen = new Gen(seed);
        all.put("sealnix/Config.seal", gen.config(Json.object(spec.get("options"))));
        all.put("sealnix/Packages.seal", gen.packages(Json.object(spec.get("packages"))));
        for (var e : program.entrySet()) {
            if (all.containsKey(e.getKey())) {
                System.err.println(e.getKey() + ": SealNix's own library has a file of this name; rename yours");
                throw new Failed();
            }
            all.put(e.getKey(), e.getValue());
        }
        return all;
    }

    /** Compiles and runs the configuration; gives each value Dump reported, by its path. */
    static Map<String, String> run(Map<String, String> sources, boolean report, Map<String, Object> spec) {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        PrintStream out = new PrintStream(buffer, true, StandardCharsets.UTF_8);
        SealScript script;
        try {
            script = SealEngine.builder().out(out).err(System.err).build().compile(sources);
        } catch (IOException e) {
            throw new IllegalStateException(e);
        }
        if (!script.ok()) {
            for (Diagnostic d : script.errors()) {
                System.err.println(d);
            }
            for (Object hint : Json.list(spec.get("unknown"))) {
                Map<String, Object> h = Json.object(hint);
                System.err.println("note: " + h.get("name") + " has no " + h.get("what") + " " + h.get("missing")
                        + suggest((String) h.get("missing"), Json.list(h.get("candidates"))));
            }
            throw new Failed();
        }
        if (report) {
            for (Diagnostic d : script.warnings()) {
                System.err.println(d);
            }
        }
        String main = (String) spec.getOrDefault("main", "Main");
        try {
            int code = script.run(main);
            if (code != 0) {
                System.err.println(main + ".main() returned " + code);
                throw new Failed();
            }
            script.run("sealnix.Dump");
        } catch (SealException e) {
            System.err.println(e.getMessage());
            throw new Failed();
        }
        Map<String, String> values = new LinkedHashMap<>();
        for (String line : buffer.toString(StandardCharsets.UTF_8).split("\n", -1)) {
            if (line.startsWith("\u0001")) {
                int tab = line.indexOf('\t');
                values.put(line.substring(1, tab), line.substring(tab + 1).replace('\u001e', '\n'));
            } else if (report && !line.isEmpty()) {
                System.err.println(line);
            }
        }
        return values;
    }

    static String suggest(String name, List<Object> candidates) {
        List<String> close = candidates.stream().map(c -> (String) c)
                .filter(c -> distance(c.toLowerCase(), name.toLowerCase()) <= Math.max(2, name.length() / 3))
                .sorted(Comparator.comparingInt(c -> distance(c.toLowerCase(), name.toLowerCase())))
                .limit(3).toList();
        return close.isEmpty() ? "" : "; did you mean " + String.join(", ", close) + "?";
    }

    static int distance(String a, String b) {
        int[] row = new int[b.length() + 1];
        for (int j = 0; j <= b.length(); j++) {
            row[j] = j;
        }
        for (int i = 1; i <= a.length(); i++) {
            int diagonal = row[0];
            row[0] = i;
            for (int j = 1; j <= b.length(); j++) {
                int above = row[j];
                row[j] = Math.min(Math.min(row[j] + 1, row[j - 1] + 1), diagonal + (a.charAt(i - 1) == b.charAt(j - 1) ? 0 : 1));
                diagonal = above;
            }
        }
        return row[b.length()];
    }

    // ---- Names ---------------------------------------------------------------------------------

    static final Set<String> SEAL_KEYWORDS = Set.of("class", "struct", "unique", "interface", "enum", "package",
            "import", "assert", "switch", "throw", "try", "catch", "finally", "case", "default", "abstract", "extends",
            "implements", "instanceof", "this", "public", "private", "static", "const", "pure", "int", "char", "uint",
            "bit", "float", "double", "void", "addr", "handle", "fixed", "ufixed", "new", "delete", "return", "if",
            "else", "while", "for", "break", "continue", "sizeof", "alignof", "super", "null", "true", "false");

    static final Set<String> NIX_KEYWORDS = Set.of("if", "then", "else", "assert", "with", "let", "in", "rec",
            "inherit", "or");

    /** A Nix name as Seal can write it: experimental-features is experimental_features, package is package_. */
    static String sealName(String nix) {
        StringBuilder b = new StringBuilder();
        for (char c : nix.toCharArray()) {
            boolean ok = c < 128 && (Character.isLetterOrDigit(c) || c == '_');
            b.append(ok ? c : '_');
        }
        String s = b.toString();
        if (s.isEmpty() || Character.isDigit(s.charAt(0))) {
            s = "_" + s;
        }
        return SEAL_KEYWORDS.contains(s) ? s + "_" : s;
    }

    /** An attribute name as Nix writes it: bare when it can be, else quoted. */
    static String nixName(String name) {
        boolean bare = !name.isEmpty() && !NIX_KEYWORDS.contains(name);
        for (int i = 0; i < name.length(); i++) {
            char c = name.charAt(i);
            boolean first = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
            boolean later = (c >= '0' && c <= '9') || c == '-' || c == '\'';
            if (!first && !(i > 0 && later)) {
                bare = false;
            }
        }
        if (bare) {
            return name;
        }
        StringBuilder b = new StringBuilder("\"");
        for (int i = 0; i < name.length(); i++) {
            char c = name.charAt(i);
            switch (c) {
                case '\\', '"' -> b.append('\\').append(c);
                case '\n' -> b.append("\\n");
                case '$' -> b.append(i + 1 < name.length() && name.charAt(i + 1) == '{' ? "\\$" : "$");
                default -> b.append(c);
            }
        }
        return b.append('"').toString();
    }

    /** A Seal string literal. */
    static String lit(String s) {
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            switch (c) {
                case '\\' -> b.append("\\\\");
                case '"' -> b.append("\\\"");
                case '\n' -> b.append("\\n");
                case '\t' -> b.append("\\t");
                case '\r' -> b.append("\\r");
                default -> {
                    if (c < 32 || c > 126) {
                        b.append(String.format("\\u%04x", (int) c));
                    } else {
                        b.append(c);
                    }
                }
            }
        }
        return b.append('"').toString();
    }

    // ---- Generating sealnix.Config and sealnix.Packages ------------------------------------------

    /** Writes the Seal classes for the options and packages in the spec; seed picks the options' starting values. */
    static final class Gen {
        final int seed;
        final StringBuilder classes = new StringBuilder();
        final Set<String> classNames = new HashSet<>();

        Gen(int seed) {
            this.seed = seed;
        }

        String config(Map<String, Object> options) {
            classNames.addAll(List.of("set", "setRaw", "sealnixPaths", "sealnixValues", "sealnixDump", "Config"));
            for (String name : options.keySet()) {
                classNames.add(sealName(name));
            }
            StringBuilder fields = new StringBuilder();
            StringBuilder dump = new StringBuilder();
            for (var e : options.entrySet()) {
                member(fields, dump, e.getKey(), Json.object(e.getValue()), List.of(e.getKey()), true);
            }
            return """
                    // Generated by SealNix for this configuration: the NixOS options it names, as Seal.
                    package sealnix;

                    import seal.util.List;

                    class Config {
                    %s
                        static List<string> sealnixPaths = new List();
                        static List<string> sealnixValues = new List();

                        // Any option, by its path as Nix names it: Config.set("services.tailscale.enable", true).
                        public static void set(string path, bit value) { setRaw(path, Text.b(value)); }
                        public static void set(string path, int<<64>> value) { setRaw(path, Text.i(value)); }
                        public static void set(string path, double value) { setRaw(path, Text.f(value)); }
                        public static void set(string path, string value) { setRaw(path, Text.s(value)); }
                        public static void set(string path, Pkg value) { setRaw(path, Text.p(value)); }
                        public static void set(string path, Nix value) { setRaw(path, Text.n(value)); }

                        // As set, with the value as Nix code: Config.setRaw("boot.kernelPackages", "pkgs.linuxPackages_latest").
                        public static void setRaw(string path, string nix) {
                            sealnixPaths.add(path);
                            sealnixValues.add(nix);
                        }

                        private<Dump> static void sealnixDump(Out o) {
                    %s        for (int k = 0; k < sealnixPaths.size(); k++) { o.dotted(sealnixPaths.get(k), sealnixValues.get(k)); }
                        }
                    %s}
                    """.formatted(fields, dump, classes);
        }

        /** The field for one option or namespace of a class, and the lines of its sealnixDump that report it. */
        void member(StringBuilder fields, StringBuilder dump, String nixName, Map<String, Object> node, List<String> path,
                boolean isStatic) {
            String field = sealName(nixName);
            String mods = isStatic ? "public static " : "public ";
            String at = lit(SealNix.nixName(nixName));
            if ("ns".equals(node.get("kind"))) {
                String cls = nodeClass(path, Json.object(node.get("children")), false);
                fields.append("    ").append(mods).append(cls).append(' ').append(field).append(" = new ").append(cls).append("();\n");
                dump.append("        o.push(").append(at).append("); ").append(field).append(".sealnixDump(o); o.pop();\n");
                return;
            }
            Map<String, Object> type = Json.object(node.get("type"));
            String k = (String) type.get("k");
            switch (k) {
                case "bit", "int", "float", "str", "pkg", "nix" -> {
                    fields.append("    ").append(mods).append(sealType(k)).append(' ').append(field).append(" = ")
                            .append(seedValue(k)).append(";\n");
                    dump.append("        o.at(").append(at).append(", Text.").append(letter(k)).append('(').append(field).append("));\n");
                }
                case "list" -> {
                    String e = (String) Json.object(type.get("e")).get("k");
                    fields.append("    ").append(mods).append("List<").append(sealType(e)).append("> ").append(field)
                            .append(" = new List();\n");
                    dump.append("        if (!").append(field).append(".isEmpty()) { o.at(").append(at).append(", Text.")
                            .append(letter(e)).append("l(").append(field).append(")); }\n");
                }
                default -> {
                    String cls = switch (k) {
                        case "attrs" -> attrsClass(path, type);
                        case "sub" -> nodeClass(path, Json.object(type.get("options")), Boolean.TRUE.equals(type.get("freeform")));
                        case "listsub" -> listClass(path, type);
                        case "attrssub" -> attrsSubClass(path, type);
                        default -> throw new IllegalArgumentException("unknown kind " + k + " at " + path);
                    };
                    fields.append("    ").append(mods).append(cls).append(' ').append(field).append(" = new ").append(cls).append("();\n");
                    dump.append("        o.push(").append(at).append("); ").append(field).append(".sealnixDump(o); o.pop();\n");
                }
            }
        }

        static List<String> names(Map<String, Object> type) {
            return Json.list(type.get("names")).stream().map(n -> (String) n).distinct().toList();
        }

        /**
         * A class's name, from its path: systemd_services_entry is a systemd.services.<name>, which a
         * configuration can name, Config.systemd_services_entry. One that a member of Config has
         * (services) gets a _.
         */
        String className(List<String> path) {
            List<String> parts = new ArrayList<>();
            for (String p : path) {
                parts.add(switch (p) {
                    case "<name>" -> "entry";
                    case "*" -> "item";
                    default -> sealName(p);
                });
            }
            String name = String.join("_", parts);
            while (!classNames.add(name)) {
                name += "_";
            }
            return name;
        }

        /** A namespace's or a submodule's options. A freeform one (settings) also takes options it doesn't declare, with set. */
        String nodeClass(List<String> path, Map<String, Object> children, boolean freeform) {
            String cls = className(path);
            StringBuilder fields = new StringBuilder();
            StringBuilder dump = new StringBuilder();
            for (var e : children.entrySet()) {
                List<String> p = new ArrayList<>(path);
                p.add(e.getKey());
                member(fields, dump, e.getKey(), Json.object(e.getValue()), p, false);
            }
            StringBuilder b = new StringBuilder();
            b.append("\n    public static class ").append(cls).append(" {\n").append(indent(fields));
            if (freeform) {
                b.append("""
                                List<string> sealnixKeys = new List();
                                List<Nix> sealnixValues = new List();

                                // A setting this module doesn't declare: settings.set("X11Forwarding", true).
                                public void set(string key, Nix value) {
                                    int at = sealnixKeys.indexOf(key);
                                    if (at >= 0) { sealnixValues.set(at, value); } else { sealnixKeys.add(key); sealnixValues.add(value); }
                                }
                                public void set(string key, bit value) { set(key, Nix.of(value)); }
                                public void set(string key, int<<64>> value) { set(key, Nix.of(value)); }
                                public void set(string key, double value) { set(key, Nix.of(value)); }
                                public void set(string key, string value) { set(key, Nix.of(value)); }
                                public void set(string key, Pkg value) { set(key, Nix.of(value)); }
                        """);
            }
            b.append("\n        void sealnixDump(Out o) {\n").append(indent(dump));
            if (freeform) {
                b.append("            for (int k = 0; k < sealnixKeys.size(); k++) { o.at(Text.name(sealnixKeys.get(k)), sealnixValues.get(k).text()); }\n");
            }
            b.append("        }\n    }\n");
            classes.append(b);
            return cls;
        }

        /** attrsOf a value: set(key, value) and get(key), and a field for each name the configuration writes. */
        String attrsClass(List<String> path, Map<String, Object> type) {
            String cls = className(path);
            Map<String, Object> elem = Json.object(type.get("e"));
            List<String> names = names(type);
            boolean list = "list".equals(elem.get("k"));
            String k = list ? (String) Json.object(elem.get("e")).get("k") : (String) elem.get("k");
            String value = list ? "List<" + sealType(k) + ">" : sealType(k);
            String text = "Text." + letter(k) + (list ? "l" : "");
            boolean anything = "nix".equals(k) && !list;
            // A name the configuration writes as a field (environment.variables.EDITOR). In a set of
            // anything (nixpkgs.config, systemd's serviceConfig) it has the type of the value the
            // configuration gives it, which nix/spec.nix found: allowUnfree = true is a bit.
            Map<String, String> fieldKind = new LinkedHashMap<>();
            for (String n : names) {
                fieldKind.put(n, anything ? (String) Json.object(type.get("nameTypes")).getOrDefault(n, "str") : k);
            }
            StringBuilder b = new StringBuilder();
            b.append("\n    public static class ").append(cls).append(" {\n");
            for (String n : names) {
                b.append("        public ").append(list ? value : sealType(fieldKind.get(n))).append(' ').append(n).append(" = ")
                        .append(list ? "new List()" : seedValue(fieldKind.get(n))).append(";\n");
            }
            b.append("        List<string> sealnixKeys = new List();\n");
            b.append("        List<").append(value).append("> sealnixValues = new List();\n\n");
            b.append("        public void set(string key, ").append(value).append(" value) {\n");
            if (!anything) {
                for (String n : names) {
                    b.append("            if (key == ").append(lit(n)).append(") { ").append(n).append(" = value; return; }\n");
                }
            }
            b.append("            int at = sealnixKeys.indexOf(key);\n");
            b.append("            if (at >= 0) { sealnixValues.set(at, value); } else { sealnixKeys.add(key); sealnixValues.add(value); }\n");
            b.append("        }\n");
            if (anything) {
                for (String t : List.of("bit", "int", "float", "str", "pkg")) {
                    b.append("        public void set(string key, ").append(sealType(t)).append(" value) {\n");
                    for (String n : names) {
                        if (fieldKind.get(n).equals(t)) {
                            b.append("            if (key == ").append(lit(n)).append(") { ").append(n).append(" = value; return; }\n");
                        }
                    }
                    b.append("            set(key, Nix.of(value));\n        }\n");
                }
            } else {
                b.append("        public bit has(string key) {\n");
                for (String n : names) {
                    b.append("            if (key == ").append(lit(n)).append(") { return true; }\n");
                }
                b.append("            return sealnixKeys.contains(key);\n        }\n");
                b.append("        public ").append(value).append(" get(string key) {\n");
                for (String n : names) {
                    b.append("            if (key == ").append(lit(n)).append(") { return ").append(n).append("; }\n");
                }
                b.append("            int at = sealnixKeys.indexOf(key);\n");
                if (list) {
                    b.append("            if (at < 0) { sealnixKeys.add(key); sealnixValues.add(new List()); at = sealnixKeys.size() - 1; }\n");
                } else {
                    b.append("            if (at < 0) { throw new IllegalArgumentException(\"no \" + key); }\n");
                }
                b.append("            return sealnixValues.get(at);\n        }\n");
            }
            b.append("\n        void sealnixDump(Out o) {\n");
            for (String n : names) {
                if (list) {
                    b.append("            if (!").append(n).append(".isEmpty()) { o.at(").append(lit(nixName(n))).append(", ")
                            .append(text).append('(').append(n).append(")); }\n");
                } else {
                    b.append("            o.at(").append(lit(nixName(n))).append(", Text.").append(letter(fieldKind.get(n)))
                            .append('(').append(n).append("));\n");
                }
            }
            b.append("            for (int k = 0; k < sealnixKeys.size(); k++) { o.at(Text.name(sealnixKeys.get(k)), ")
                    .append(text).append("(sealnixValues.get(k))); }\n");
            b.append("        }\n    }\n");
            classes.append(b);
            return cls;
        }

        /** listOf a submodule: add() gives a new element. */
        String listClass(List<String> path, Map<String, Object> type) {
            String cls = className(path);
            List<String> p = new ArrayList<>(path);
            p.add("*");
            String item = nodeClass(p, Json.object(type.get("options")), Boolean.TRUE.equals(type.get("freeform")));
            classes.append("""

                        public static class %1$s {
                            List<%2$s> sealnixItems = new List();

                            public %2$s add() {
                                %2$s item = new %2$s();
                                sealnixItems.add(item);
                                return item;
                            }
                            public %2$s get(int index) { return sealnixItems.get(index); }
                            public int size() { return sealnixItems.size(); }

                            void sealnixDump(Out o) {
                                for (int k = 0; k < sealnixItems.size(); k++) {
                                    o.push("#" + k);
                                    o.exists();
                                    sealnixItems.get(k).sealnixDump(o);
                                    o.pop();
                                }
                            }
                        }
                    """.formatted(cls, item));
            return cls;
        }

        /** attrsOf a submodule: get(name) gives the one of that name, and the configuration's names are fields too. */
        String attrsSubClass(List<String> path, Map<String, Object> type) {
            String cls = className(path);
            List<String> p = new ArrayList<>(path);
            p.add("<name>");
            String entry = nodeClass(p, Json.object(type.get("options")), Boolean.TRUE.equals(type.get("freeform")));
            List<String> names = names(type);
            StringBuilder b = new StringBuilder();
            b.append("\n    public static class ").append(cls).append(" {\n");
            for (String n : names) {
                b.append("        public ").append(entry).append(' ').append(n).append(" = new ").append(entry).append("();\n");
                b.append("        bit sealnixGot_").append(n).append(" = false;\n");
            }
            b.append("        List<string> sealnixKeys = new List();\n");
            b.append("        List<").append(entry).append("> sealnixValues = new List();\n\n");
            b.append("        public ").append(entry).append(" get(string name) {\n");
            for (String n : names) {
                b.append("            if (name == ").append(lit(n)).append(") { sealnixGot_").append(n).append(" = true; return ")
                        .append(n).append("; }\n");
            }
            b.append("            int at = sealnixKeys.indexOf(name);\n");
            b.append("            if (at < 0) { sealnixKeys.add(name); sealnixValues.add(new ").append(entry)
                    .append("()); at = sealnixKeys.size() - 1; }\n");
            b.append("            return sealnixValues.get(at);\n        }\n");
            b.append("        public bit has(string name) {\n");
            for (String n : names) {
                b.append("            if (name == ").append(lit(n)).append(" && sealnixGot_").append(n).append(") { return true; }\n");
            }
            b.append("            return sealnixKeys.contains(name);\n        }\n");
            b.append("\n        void sealnixDump(Out o) {\n");
            for (String n : names) {
                b.append("            o.push(").append(lit(nixName(n))).append("); if (sealnixGot_").append(n)
                        .append(") { o.exists(); } ").append(n).append(".sealnixDump(o); o.pop();\n");
            }
            b.append("            for (int k = 0; k < sealnixKeys.size(); k++) {\n");
            b.append("                o.push(Text.name(sealnixKeys.get(k))); o.exists(); sealnixValues.get(k).sealnixDump(o); o.pop();\n");
            b.append("            }\n        }\n    }\n");
            classes.append(b);
            return cls;
        }

        static String sealType(String k) {
            return switch (k) {
                case "bit" -> "bit";
                case "int" -> "int<<64>>";
                case "float" -> "double";
                case "str" -> "string";
                case "pkg" -> "Pkg";
                default -> "Nix";
            };
        }

        static String letter(String k) {
            return switch (k) {
                case "bit" -> "b";
                case "int" -> "i";
                case "float" -> "f";
                case "str" -> "s";
                case "pkg" -> "p";
                default -> "n";
            };
        }

        /** Where an option starts: another value in each run, so that one the program never set differs. */
        String seedValue(String k) {
            boolean first = seed == 0;
            return switch (k) {
                case "bit" -> first ? "false" : "true";
                case "int" -> first ? "0" : "1";
                case "float" -> first ? "0.0" : "1.0";
                case "str" -> first ? "\"\"" : "\"\\u0001unset\"";
                case "pkg" -> first ? "new Pkg(\"\\u0001a\")" : "new Pkg(\"\\u0001b\")";
                default -> first ? "new Nix(\"\\u0001a\")" : "new Nix(\"\\u0001b\")";
            };
        }

        static String indent(CharSequence s) {
            return s.toString().replaceAll("(?m)^(.)", "    $1");
        }

        /** Packages.fastfetch, Packages.kdePackages.kate: the packages the configuration names. */
        String packages(Map<String, Object> tree) {
            StringBuilder b = new StringBuilder("""
                    // Generated by SealNix for this configuration: the nixpkgs packages it names, as Seal.
                    package sealnix;

                    class Packages {
                    """);
            packageMembers(b, tree, "    ");
            return b.append("}\n").toString();
        }

        void packageMembers(StringBuilder b, Map<String, Object> tree, String indent) {
            for (var e : tree.entrySet()) {
                Map<String, Object> node = Json.object(e.getValue());
                if (node.containsKey("$pkg")) {
                    StringBuilder expr = new StringBuilder("pkgs");
                    for (Object part : Json.list(node.get("$pkg"))) {
                        expr.append('.').append(nixName((String) part));
                    }
                    b.append(indent).append("public static Pkg ").append(e.getKey()).append(" = new Pkg(")
                            .append(lit(expr.toString())).append(");\n");
                } else {
                    b.append(indent).append("public static class ").append(e.getKey()).append(" {\n");
                    packageMembers(b, node, indent + "    ");
                    b.append(indent).append("}\n");
                }
            }
        }
    }

    // ---- The module ----------------------------------------------------------------------------

    /** What the configuration set, as a tree of attribute names; a name "#0" is a list's first element. */
    static final class Node {
        String value;
        boolean exists;
        final Map<String, Node> children = new LinkedHashMap<>();

        void put(List<String> path, String nix) {
            Node n = this;
            for (String name : path) {
                n = n.children.computeIfAbsent(name, x -> new Node());
            }
            if ("\u0002".equals(nix)) {
                n.exists = true;
            } else {
                n.value = nix;
            }
        }

        boolean isList() {
            return !children.isEmpty() && children.keySet().stream().allMatch(k -> k.startsWith("#"));
        }
    }

    static String module(Node root, Set<String> files) {
        return "# Generated by SealNix from " + String.join(", ", files) + ": edit those, not this file.\n"
                + "{ config, lib, pkgs, ... }:\n" + attrs(root, 0, "") + "\n";
    }

    static String attrs(Node n, int indent, String where) {
        if (n.children.isEmpty()) {
            return "{ }";
        }
        StringBuilder b = new StringBuilder("{\n");
        for (var e : n.children.entrySet()) {
            String name = e.getKey();
            Node c = e.getValue();
            while (c.value == null && c.children.size() == 1 && !c.isList()) {
                var only = c.children.entrySet().iterator().next();
                name += "." + only.getKey();
                c = only.getValue();
            }
            String path = where.isEmpty() ? name : where + "." + name;
            b.append(" ".repeat(indent + 2)).append(name).append(" = ").append(value(c, indent + 2, path)).append(";\n");
        }
        return b.append(" ".repeat(indent)).append('}').toString();
    }

    static String value(Node n, int indent, String path) {
        if (n.value != null) {
            if (!n.children.isEmpty()) {
                System.err.println(path + " is set twice: as a whole, and its " + n.children.keySet().iterator().next());
                throw new Failed();
            }
            return leaf(n.value, indent);
        }
        if (n.isList()) {
            StringBuilder b = new StringBuilder("[\n");
            for (Node item : n.children.values()) {
                b.append(" ".repeat(indent + 2)).append(attrs(item, indent + 2, path)).append('\n');
            }
            return b.append(" ".repeat(indent)).append(']').toString();
        }
        return attrs(n, indent, path);
    }

    /** A value's Nix; a list, which Text marks, on one line when it fits, else one item to a line. */
    static String leaf(String nix, int indent) {
        if (!nix.startsWith("\u0003")) {
            return nix;
        }
        String body = nix.substring(1);
        if (body.isEmpty()) {
            return "[ ]";
        }
        String[] items = body.split("\u001d", -1);
        String line = "[ " + String.join(" ", items) + " ]";
        if (indent + line.length() <= 90 && !line.contains("\n")) {
            return line;
        }
        StringBuilder b = new StringBuilder("[\n");
        for (String item : items) {
            b.append(" ".repeat(indent + 2)).append(item).append('\n');
        }
        return b.append(" ".repeat(indent)).append(']').toString();
    }

    // ---- JSON, as nix/spec.nix writes it ---------------------------------------------------------

    static final class Json {
        final String s;
        int i;

        Json(String s) {
            this.s = s;
        }

        @SuppressWarnings("unchecked")
        static Map<String, Object> object(Object o) {
            return o == null ? Map.of() : (Map<String, Object>) o;
        }

        @SuppressWarnings("unchecked")
        static List<Object> list(Object o) {
            return o == null ? List.of() : (List<Object>) o;
        }

        Object value() {
            space();
            char c = s.charAt(i);
            switch (c) {
                case '{' -> {
                    i++;
                    Map<String, Object> m = new LinkedHashMap<>();
                    space();
                    if (s.charAt(i) == '}') {
                        i++;
                        return m;
                    }
                    while (true) {
                        space();
                        String k = string();
                        space();
                        expect(':');
                        m.put(k, value());
                        space();
                        if (s.charAt(i++) == '}') {
                            return m;
                        }
                    }
                }
                case '[' -> {
                    i++;
                    List<Object> l = new ArrayList<>();
                    space();
                    if (s.charAt(i) == ']') {
                        i++;
                        return l;
                    }
                    while (true) {
                        l.add(value());
                        space();
                        if (s.charAt(i++) == ']') {
                            return l;
                        }
                    }
                }
                case '"' -> {
                    return string();
                }
                default -> {
                    if (s.startsWith("true", i)) {
                        i += 4;
                        return Boolean.TRUE;
                    }
                    if (s.startsWith("false", i)) {
                        i += 5;
                        return Boolean.FALSE;
                    }
                    if (s.startsWith("null", i)) {
                        i += 4;
                        return null;
                    }
                    int start = i;
                    while (i < s.length() && "+-0123456789.eE".indexOf(s.charAt(i)) >= 0) {
                        i++;
                    }
                    return Double.parseDouble(s.substring(start, i));
                }
            }
        }

        String string() {
            expect('"');
            StringBuilder b = new StringBuilder();
            while (true) {
                char c = s.charAt(i++);
                if (c == '"') {
                    return b.toString();
                }
                if (c != '\\') {
                    b.append(c);
                    continue;
                }
                char e = s.charAt(i++);
                switch (e) {
                    case 'n' -> b.append('\n');
                    case 't' -> b.append('\t');
                    case 'r' -> b.append('\r');
                    case 'b' -> b.append('\b');
                    case 'f' -> b.append('\f');
                    case 'u' -> {
                        b.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
                        i += 4;
                    }
                    default -> b.append(e);
                }
            }
        }

        void space() {
            while (i < s.length() && Character.isWhitespace(s.charAt(i))) {
                i++;
            }
        }

        void expect(char c) {
            if (s.charAt(i) != c) {
                throw new IllegalArgumentException("spec: expected " + c + " at " + i);
            }
            i++;
        }
    }

}
