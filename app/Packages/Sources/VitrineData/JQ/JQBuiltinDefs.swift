import Foundation

/// The built-ins jq 1.7 itself defines in jq, written here from the jq manual's descriptions (the rest are Swift
/// natives in `JQNatives`). Parsed and bound once, on first use. Being jq, they work in path expressions where jq's
/// do (`select`, `recurse`, `first`, `paths`, `getpath`, …), so `del(.. | select(. == null))` and
/// `(.[] | select(.ok)).n |= . + 1` behave as in jq. roadmap: S-5
enum JQBuiltinDefs {
    static let source = """
    def select(f): if f then . else empty end;
    def values: select(. != null);
    def nulls: select(. == null);
    def booleans: select(type == "boolean");
    def numbers: select(type == "number");
    def strings: select(type == "string");
    def arrays: select(type == "array");
    def objects: select(type == "object");
    def iterables: select(type | . == "array" or . == "object");
    def scalars: select(type | . != "array" and . != "object");
    def finites: select(isinfinite or isnan | not);
    def normals: select(isnormal);
    def map(f): [.[] | f];
    def map_values(f): .[] |= f;
    def recurse_down: recurse;
    def to_entries: [keys_unsorted[] as $k | {key: $k, value: .[$k]}];
    def from_entries: reduce .[] as $x ({};
        . + { ($x | if .key == null then .k // .name // .Name // .K // .Key else .key end
                 | if type == "string" then . else tojson end):
              ($x | if has("value") then .value elif has("v") then .v else .Value end) });
    def with_entries(f): to_entries | map(f) | from_entries;
    def del(f): delpaths([path(f)]);
    def paths: path(..) | select(length > 0);
    def paths(node_filter): . as $dot | paths | select(. as $p | $dot | getpath($p) | node_filter);
    def leaf_paths: paths(scalars);
    def isempty(g): first((g | false), true);
    def any(generator; condition): isempty(first(generator | condition or empty)) | not;
    def all(generator; condition): isempty(first(generator | condition and empty));
    def any(condition): any(.[]; condition);
    def all(condition): all(.[]; condition);
    def in(xs): . as $x | xs | has($x);
    def inside(xs): . as $x | xs | contains($x);
    def first: .[0];
    def last: .[-1];
    def nth($n): .[$n];
    def nth($n; f): if $n < 0 then error("Out of bounds negative array index") else last(limit($n + 1; f)) end;
    def combinations: if length == 0 then [] else .[0][] as $x | (.[1:] | combinations) as $w | [$x] + $w end;
    def combinations(n): . as $dot | [range(n)] | map($dot) | combinations;
    def walk(f): def w: if type == "object" then map_values(w) elif type == "array" then map(w) else . end | f; w;
    def transpose: if . == [] then [] else . as $in | (map(length) | max) as $max
        | [range(0; $max) as $j | [range(0; $in | length) as $i | $in[$i][$j]]] end;
    def index($i): indices($i) | .[0];
    def rindex($i): indices($i) | .[-1:][0];
    def splits($re): splits($re; null);
    def splits($re; flags): split($re; flags) | .[];
    def todate: strftime("%Y-%m-%dT%H:%M:%SZ");
    def todateiso8601: strftime("%Y-%m-%dT%H:%M:%SZ");
    def fromdateiso8601: strptime("%Y-%m-%dT%H:%M:%SZ") | mktime;
    def fromdate: fromdateiso8601;
    def date: todate;
    def dateadd(u; n): . + n;
    def datesub(u; n): . - n;
    def tostream: path(def r: (.[]? | r), .; r) as $p | getpath($p) | reduce path(.[]?) as $q ([$p, .]; [$p + $q]);
    def fromstream(f): { x: null, e: false } as $init
        | foreach f as $i ($init;
            if .e then $init else . end
            | if $i | length == 2
              then setpath(["e"]; $i[0] | length == 0) | setpath(["x"] + $i[0]; $i[1])
              else setpath(["e"]; $i[0] | length == 1) end;
            if .e then .x else empty end);
    def truncate_stream(stream): . as $n | null | stream | . as $input
        | if (.[0] | length) > $n then setpath([0]; .[0][$n:]) else empty end;
    def pick(pathexps): . as $top | reduce path(pathexps) as $p (null; setpath($p; $top | getpath($p)));
    def IN(s): any(s == .; .);
    def IN(src; s): any(src == s; .);
    def INDEX(stream; idx_expr): reduce stream as $row ({}; .[$row | idx_expr | tostring] |= $row);
    def INDEX(idx_expr): INDEX(.[]; idx_expr);
    """

    static let table: [String: JQFuncDef] = build()

    private static func build() -> [String: JQFuncDef] {
        do {
            var parser = JQParser(source, builtin: true)
            var node = try parser.parseProgram()
            var defs: [String: JQFuncDef] = [:]
            while case .funcDef(let def, let rest) = node {
                defs["\(def.name)/\(def.params.count)"] = def
                node = rest
            }
            try JQResolver.resolveBuiltins(defs, source: source)
            return defs
        } catch {
            // The definitions are fixed text covered by the tests; a failure here is a programming error.
            preconditionFailure("jq built-in definitions failed to compile: \(error)")
        }
    }
}
