# Compare canonical decimal strings without losing int64 precision in awk doubles.
function decimal(s) { return s ~ /^(0|[1-9][0-9]*)$/ }
function leq(a, b) {
    if (length(a) != length(b)) return length(a) < length(b)
    return ("x" a) <= ("x" b)
}
function value(field, prefix) {
    if (index(field, prefix) != 1) bad = 1
    return substr(field, length(prefix) + 1)
}
$1 == "royd" && $2 == "interface" && $3 == "quota:" {
    count++
    if (NF != 10 || $4 != "error=0" || $9 != "invalid_drops=0" || $10 != "contention_drops=0") bad = 1
    active = value($5, "active=")
    generation = value($6, "generation=")
    limit = value($7, "limit=")
    remaining = value($8, "remaining=")
    if (!decimal(generation) || !decimal(limit) || !decimal(remaining)) bad = 1
    if (!leq(generation, "18446744073709551615") || !leq(limit, "9223372036854775807") || !leq(remaining, limit)) bad = 1
    if (active == "no") {
        if (generation != "0" || limit != "0" || remaining != "0") bad = 1
    } else if (active == "yes") {
        if (generation == "0" || limit == "0") bad = 1
    } else bad = 1
}
END { exit (count != 1 || bad) }
