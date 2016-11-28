package main;

sub ok { "ok 1\n" if -e q{/} }

print "1..1\n";
print ok();
