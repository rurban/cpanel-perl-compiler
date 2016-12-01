#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;

plan(skip_all => "Your system has no SIGALRM") if !exists $SIG{ALRM};
plan(tests => 8);

=pod

These are like the 010_complex_merge_classless test,
but an infinite loop has been made in the heirarchy,
to test that we can fail cleanly instead of going
into an infinite loop

=cut

# initial setup, everything sane
{
    package KK;
    our @ISA = qw/JJ II/;
    package JJ;
    our @ISA = qw/FF/;
    package II;
    our @ISA = qw/HH FF/;
    package HH;
    our @ISA = qw/GG/;
    package GG;
    our @ISA = qw/DD/;
    package FF;
    our @ISA = qw/EE/;
    package EE;
    our @ISA = qw/DD/;
    package DD;
    our @ISA = qw/AA BB CC/;
    package CC;
    our @ISA = qw//;
    package BB;
    our @ISA = qw//;
    package AA;
    our @ISA = qw//;
}

# A series of 8 aberations that would cause infinite loops,
#  each one undoing the work of the previous
my @loopies = (
    sub { @EE::ISA = qw/FF/ },
    sub { @EE::ISA = qw/DD/; @CC::ISA = qw/FF/ },
    sub { @CC::ISA = qw//;   @AA::ISA = qw/KK/ },
    sub { @AA::ISA = qw//;   @JJ::ISA = qw/FF KK/ },
    sub { @JJ::ISA = qw/FF/; @HH::ISA = qw/KK GG/ },
    sub { @HH::ISA = qw/GG/; @BB::ISA = qw/BB/ },
    sub { @BB::ISA = qw//;   @KK::ISA = qw/KK JJ II/ },
    sub { @KK::ISA = qw/JJ II/; @DD::ISA = qw/AA HH BB CC/ },
);

foreach my $loopy (@loopies) {
    eval {
        local $SIG{ALRM} = sub { die "ALRMTimeout" };
        alarm(3);
        $loopy->();
        mro::get_linear_isa('KK', 'dfs');
    };

    if(my $err = $@) {
        if($err =~ /ALRMTimeout/) {
            ok(0, "Loop terminated by SIGALRM");
        }
        elsif($err =~ /Recursive inheritance detected/) {
            ok(1, "Graceful exception thrown");
        }
        else {
            ok(0, "Unrecognized exception: $err");
        }
    }
    else {
        ok(0, "Infinite loop apparently succeeded???");
    }
}
