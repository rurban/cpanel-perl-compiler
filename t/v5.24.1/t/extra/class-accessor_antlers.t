package Foo;

use Class::Accessor qw(antlers);

sub fake { 1 }    # populate stash
has type => ( is => 'rw', isa => 'Str' );

print qq{1..1\n};
print qq{ok\n};
