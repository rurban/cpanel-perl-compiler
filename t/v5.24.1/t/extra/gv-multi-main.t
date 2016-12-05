package main;

sub ok { "ok 1\n" }
our @ok = (qw{ok 2}, "\n");
our %ok = ( 1 => q{ok}, 2 => "3\n" );

print "1..4\n";
print ok();
print join(' ', @ok);
print join(' ', $ok{1}, $ok{2});
print "ok 4 - done\n";
