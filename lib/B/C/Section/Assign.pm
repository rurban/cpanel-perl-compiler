package B::C::Section::Assign;
use strict;
use warnings;

# avoid use vars
use parent 'B::C::Section';

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);
    return $self;
}

sub add {    # for now simply perform a single add
    my ( $self, @args ) = @_;

    my $line = join ', ', @args;
    return $self->SUPER::add($line);
}

1;
