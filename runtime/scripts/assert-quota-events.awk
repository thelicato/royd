function le(a,b) { return length(a)<length(b) || (length(a)==length(b) && ("x" a)<=("x" b)) }
function number(s,max) { return s ~ /^(0|[1-9][0-9]*)$/ && le(s,max) }
function value(field,key,parts) {
    if (split(field,parts,"=")!=2 || parts[1]!=key) { bad=1; return "" }
    return parts[2]
}
/^royd quota events:/ {
    count++
    if (NF!=10) bad=1
    generation=value($4,"generation"); bytes=value($5,"bytes")
    armed=value($6,"armed"); started=value($7,"started")
    committed=value($8,"committed"); error=value($9,"error"); interval=value($10,"sample_ms")
    if (!number(generation,"18446744073709551615") || !number(bytes,"9223372036854775807") ||
        !number(committed,"18446744073709551615") || error!="0" || interval!="250" ||
        (armed!="yes" && armed!="no") || (started!="yes" && started!="no")) bad=1
    if (started=="no" && (generation!="0" || bytes!="0" || committed!="0" || armed!="no")) bad=1
    if (generation=="0" && (bytes!="0" || committed!="0" || armed!="no")) bad=1
    if (bytes=="0" && armed!="no") bad=1
    if (bytes!="0" && (generation=="0" || started!="yes" || (armed=="no" && committed=="0"))) bad=1
}
END {
    if (bad || count!=1) exit 1
    print generation=="0" ? "unused" : "used"
}
