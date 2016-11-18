#!./perl -w

print "1..1\n";

# The return statement should make no difference in this case:
use feature 'lexical_subs';
no warnings 'experimental::lexical_subs';
sub xyz ()     { 42 }
my sub abcd () { 42 }
eval { ${ \abcd }++ };
if ( $@ eq "" ) {
    print "ok 1\n";
}

