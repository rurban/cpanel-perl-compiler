package main; our @list = ( qw{ok 1}, "some text\n" ); print "1..2\n"; print join(" ", @list); print "ok 2\n" if $list[1] == 1;
