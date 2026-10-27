"""Extract the production query functions for the optional private-netns gate."""
from pathlib import Path
import sys


def function(text, signature):
    start = text.index(signature)
    opening = text.index('{',start)
    depth = 1
    for n in range(opening+1,len(text)):
        depth += (text[n] == '{') - (text[n] == '}')
        if depth == 0: return text[start:n+1]+'\n'
    raise AssertionError('incomplete production function')


quota, accounting, output = map(Path,sys.argv[1:])
source = accounting.read_text()
output.write_text(function(source,'template <typename T> inline bool info(')
                  + function(source,'inline bool validLink(')
                  + function(quota.read_text(),'inline bool quotaLink('))
