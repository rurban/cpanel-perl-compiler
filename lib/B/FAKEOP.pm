package B::FAKEOP;

our @ISA = qw(B::OP);

use B::C::File qw/opsect init/;

sub new {
    my ( $class, %objdata ) = @_;
    bless \%objdata, $class;
}

sub save {
    my ( $op, $level ) = @_;
    my $ix = opsect()->sadd( "%s, %s, %s", $op->next, $op->sibling, $op->_save_common_middle );
    return "&op_list[$ix]";
}

*_save_common_middle = \&B::OP::_save_common_middle;
sub next    { $_[0]->{"next"}  || 0 }
sub type    { $_[0]->{type}    || 0 }
sub sibling { $_[0]->{sibling} || 0 }
sub ppaddr  { $_[0]->{ppaddr}  || 0 }
sub targ    { $_[0]->{targ}    || 0 }
sub flags   { $_[0]->{flags}   || 0 }
sub private { $_[0]->{private} || 0 }

sub fake_ppaddr { "NULL" }

1;
