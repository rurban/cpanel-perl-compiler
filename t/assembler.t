#!./perl -w

=pod

=head1 TEST FOR B::Assembler.pm AND B::Disassembler.pm

=head2 Description

The general idea is to test by assembling a choice set of assembler
instructions, then disassemble them, and check that we've completed the
round trip. Also, error checking of Assembler.pm is tested by feeding
it assorted errors.

Since Assembler.pm likes to assemble a file, we comply by writing a
text file. This file contains three sections:

  testing operand categories
  use each opcode
  erronous assembler instructions

An "operand category" is identified by the suffix of the PUT_/GET_
subroutines as shown in the C<%Asmdata::insn_data> initialization, e.g.
opcode C<ldsv> has operand category C<svindex>:

   insn_data{ldsv} = [1, \&PUT_svindex, "GET_svindex"];

Because Disassembler.pm also assumes input from a file, we write the
resulting object code to a file. And disassembled output is written to
yet another text file which is then compared to the original input.
(Erronous assembler instructions still generate code, but this is not
written to the object file; therefore disassembly bails out at the first
instruction in error.)

All files are kept in memory by using TIEHASH.


=head2 Caveats

An error where Assembler.pm and Disassembler.pm agree but Assembler.pm
generates invalid object code will not be detected.

Due to the way this test has been set up, failure of a single test
could cause all subsequent tests to fail as well: After an unexpected
assembler error no output is written, and disassembled lines will be
out of sync for all lines thereafter.

Not all possibilities for writing a valid operand value can be tested
because disassembly results in a uniform representation.


=head2 Maintenance

New opcodes are added automatically.

A new operand category will cause this program to die ("no operand list
for XXX"). The cure is to add suitable entries to C<%goodlist> and
C<%badlist>. (Since the data in Asmdata.pm is autogenerated, it may also
happen that the corresponding assembly or disassembly subroutine is
missing.) Note that an empty array as a C<%goodlist> entry means that
opcodes of the operand category do not take an operand (and therefore the
corresponding entry in C<%badlist> should have one). An C<undef> entry
in C<%badlist> means that any value is acceptable (and thus there is no
way to cause an error).

Set C<$dbg> to debug this test.

B::Disassembler was enhanced to add comments about some insn.
The additional third verbose argument for easier roundtrip checking
is ignored.

=cut

package VirtFile;
use strict;

# Note: This is NOT a general purpose package. It implements
# sequential text and binary file i/o in a rather simple form.

sub TIEHANDLE($;$){
    my( $class, $data ) = @_;
    my $obj = { data => defined( $data ) ? $data : '',
                pos => 0 };
    return bless( $obj, $class );
}

sub PRINT($@){
    my( $self ) = shift;
    $self->{data} .= join( '', @_ );
}

sub WRITE($$;$$){
    my( $self, $buf, $len, $offset ) = @_;
    unless( defined( $len ) ){
	$len = length( $buf );
        $offset = 0;
    }
    unless( defined( $offset ) ){
        $offset = 0;
    }
    $self->{data} .= substr( $buf, $offset, $len );
    return $len;
}


sub GETC($){
    my( $self ) = @_;
    return undef() if $self->{pos} >= length( $self->{data} );
    return substr( $self->{data}, $self->{pos}++, 1 );
}

sub READLINE($){
    my( $self ) = @_;
    return undef() if $self->{pos} >= length( $self->{data} );
    # Todo; strip comments and empty lines
    my $lfpos = index( $self->{data}, "\n", $self->{pos} );
    if( $lfpos < 0 ){
        $lfpos = length( $self->{data} );
    }
    my $pos = $self->{pos};
    $self->{pos} = $lfpos + 1;
    return substr( $self->{data}, $pos, $self->{pos} - $pos );
}

sub READ($@){
    my $self = shift();
    my $bufref = \$_[0];
    my( undef, $len, $offset ) = @_;
    if( $offset ){
        die( "offset beyond end of buffer\n" )
          if ! defined( $$bufref ) || $offset > length( $$bufref );
    } else {
        $$bufref = '';
        $offset = 0;
    }
    my $remlen = length( $self->{data} ) - $self->{pos};
    $len = $remlen if $remlen < $len;
    return 0 unless $len;
    substr( $$bufref, $offset, $len ) =
      substr( $self->{data}, $self->{pos}, $len );
    $self->{pos} += $len;
    return $len;
}

sub TELL($){
    my $self = shift();
    return $self->{pos};
}

sub CLOSE($){
    my( $self ) = @_;
    $self->{pos} = 0;
}

1;

package main;

use strict;
use Test::More;
use Config qw(%Config);

BEGIN {
  if ($ENV{PERL_CORE} and ($Config{'extensions'} !~ /\bB\b/) ){
    print "1..0 # Skip -- Perl configured without B module\n";
    exit 0;
  }
  if ($ENV{PERL_CORE} and ($Config{'extensions'} !~ /\bByteLoader\b/) ){
    print "1..0 # Skip -- Perl configured without ByteLoader module\n";
    exit 0;
  }
}

use B::Asmdata      qw( %insn_data );
use B::Assembler    qw( &assemble_fh );
use B::Disassembler qw( &disassemble_fh &get_header );

my( %opsByType, @code2name );
my( $lineno, $dbg, $firstbadline, @descr );
$dbg = 0; # debug switch

# $SIG{__WARN__} handler to catch Assembler error messages
#
my $warnmsg;
sub catchwarn($){
    $warnmsg = $_[0];
    print "# error: $warnmsg\n" if $dbg;
}

# Callback for writing assembled bytes. This is where we check
# that we do get an error.
#
sub putobj($){
    if( ++$lineno >= $firstbadline ){
        ok( $warnmsg && $warnmsg =~ /^\d+:\s/, $descr[$lineno] );
        undef( $warnmsg );
    } else {
        my $l = syswrite( OBJ, $_[0] );
    }
}

# Callback for writing a disassembled statement.
# Fixed to support the new optional verbose argument, which we ignore here.
sub putdis(@){
    my ($insn, $arg, $verbose) = @_;
    my $line = defined($arg) ? "$insn $arg" : $insn;
    ++$lineno;
    print DIS "$line\n";
    printf ("# %5d %s verbose:%d\n", $lineno, $line, $verbose) if $dbg;
}

# Generate assembler instructions from a hash of operand types: each
# existing entry contains a list of good or bad operand values. The
# corresponding opcodes can be found in %opsByType.
#
sub gen_type($$$){
    my( $href, $descref, $text ) = @_;
    for my $odt ( sort( keys( %opsByType ) ) ){
        my $opcode = $opsByType{$odt}->[0];
	my $sel = $odt;
	$sel =~ s/^GET_//;
	die( "no operand list for $sel\n" ) unless exists( $href->{$sel} );
        if( defined( $href->{$sel} ) ){
            if( @{$href->{$sel}} ){
		for my $od ( @{$href->{$sel}} ){
		    ++$lineno;
                    $descref->[$lineno] = "$text: $code2name[$opcode] $od";
		    print ASM "$code2name[$opcode] $od\n";
		    printf "# %5d %s %s\n", $lineno, $code2name[$opcode], $od if $dbg;
		}
	    } else {
		++$lineno;
                $descref->[$lineno] = "$text: $code2name[$opcode]";
		print ASM "$code2name[$opcode]\n";
		printf "# %5d %s\n", $lineno, $code2name[$opcode] if $dbg;
	    }
	}
    }
}

# Interesting operand values
#
my %goodlist = (
comment_t   => [ '"a comment"' ],  # no \n
none        => [],
svindex     => [ 0x7fffffff, 0 ],
opindex     => [ 0x7fffffff, 0 ],
pvindex     => [ 0x7fffffff, 0 ],
hekindex    => [ 0x7fffffff, 0 ],
U32         => [ 0xffffffff, 0 ],
U8          => [ 0xff, 0 ],
PV          => [ '""', '"a string"', ],
I32         => [ -0x80000000, 0x7fffffff ],
IV64        => [ '0x000000000', '0x0ffffffff', '0x000000001' ], # disass formats  0x%09x
IV          => $Config{ivsize} == 4 ?
               [ -0x80000000, 0x7fffffff ] :
               [ '0x000000000', '0x0ffffffff', '0x000000001' ],
NV          => [ 1.23456789E3 ],
U16         => [ 0xffff, 0 ],
pvcontents  => [],
strconst    => [ '""', '"another string"' ], # no NUL
op_tr_array => [ join( ',', 256, 0..255 ) ],
PADOFFSET   => undef,
long        => undef,
	      );

# Erronous operand values
#
my %badlist = (
comment_t   => [ '"multi-line\ncomment"' ],  # no \n
none        => [ '"spurious arg"'  ],
svindex     => [ 0xffffffff * 2, -1 ],
opindex     => [ 0xffffffff * 2, -2 ],
pvindex     => [ 0xffffffff * 2, -3 ],
hekindex    => [ 0xffffffff * 2, -4 ],
U32         => [ 0xffffffff * 2, -5 ],
U16         => [ 0x5ffff, -5 ],
U8          => [ 0x6ff, -6 ],
PV          => [ 'no quote"' ],
I32         => [ -0x80000001, 0x80000000 ],
IV64        => undef, # PUT_IV64 doesn't check - no integrity there
IV          => $Config{ivsize} == 4 ?
               [ -0x80000001, 0x80000000 ] : undef,
NV          => undef, # PUT_NV accepts anything - it shouldn't, real-ly
pvcontents  => [ '"spurious arg"' ],
strconst    => [  'no quote"',  '"with NUL '."\0".' char"' ], # no NUL
op_tr_array => undef, # op_pv_tr is no longer exactly 256 shorts
PADOFFSET   => undef,
long	     => undef,
	      );


# Determine all operand types from %Asmdata::insn_data
#
for my $opname ( keys( %insn_data ) ){
    my ( $opcode, $put, $getname ) = @{$insn_data{$opname}};
    push( @{$opsByType{$getname}}, $opcode );
    $code2name[$opcode] = $opname;
}


# Write instruction(s) for correct operand values each operand type class
#
$lineno = 0;
tie( *ASM, 'VirtFile' );
gen_type( \%goodlist, \@descr, 'round trip' );

# Write one instruction for each opcode.
#
for my $opcode ( 0..$#code2name ){
    next unless defined( $code2name[$opcode] );
    my $sel = $insn_data{$code2name[$opcode]}->[2];
    $sel =~ s/^GET_//;
    die( "no operand list for $sel\n" ) unless exists( $goodlist{$sel} );
    if( defined( $goodlist{$sel} ) ){
        ++$lineno;
        if( @{$goodlist{$sel}} ){
            my $od = $goodlist{$sel}[0];
            $descr[$lineno] = "round trip: $code2name[$opcode] $od";
            print ASM "$code2name[$opcode] $od\n";
            printf "# %5d %s %s\n", $lineno, $code2name[$opcode], $od if $dbg;
        } else {
            $descr[$lineno] = "round trip: $code2name[$opcode]";
            print ASM "$code2name[$opcode]\n";
            printf "# %5d %s\n", $lineno, $code2name[$opcode] if $dbg;
	}
    }
}

# Write instruction(s) for incorrect operand values each operand type class
#
$firstbadline = $lineno + 1;
gen_type( \%badlist, \@descr, 'asm error' );

# invalid opcode is an odd-man-out ;-)
#
++$lineno;
$descr[$lineno] = "asm error: Gollum";
print ASM "Gollum\n";
printf "# %5d %s\n", $lineno, 'Gollum' if $dbg;

close( ASM );

# Now that we have defined all of our tests: plan
#
plan( tests => $lineno );
print "# firstbadline=$firstbadline\n" if $dbg;

# assemble (guard against warnings and death from assembly errors)
#
$SIG{'__WARN__'} = \&catchwarn;

$lineno = -1; # account for the assembly header
tie( *OBJ, 'VirtFile' );
eval { assemble_fh( \*ASM, \&putobj ); };
print "# eval: $@" if $dbg;
close( ASM );
close( OBJ );
$SIG{'__WARN__'} = 'DEFAULT';

# disassemble
#
print "# --- disassembling ---\n" if $dbg;
$lineno = 0;
tie( *DIS, 'VirtFile' );
disassemble_fh( \*OBJ, \&putdis );
close( OBJ );
close( DIS );

# get header (for debugging only)
#
if( $dbg ){
    my( $magic, $archname, $blversion, $ivsize, $ptrsize, $byteorder, $longsize ) =
        get_header();
    printf "# Magic:        0x%08x\n", $magic;
    print  "# Architecture: $archname\n";
    print  "# Byteloader V: $blversion\n";
    print  "# ivsize:       $ivsize\n";
    print  "# ptrsize:      $ptrsize\n";
    print  "# longsize:     $longsize\n";
    print  "# Byteorder:    $byteorder\n";
}

# check by comparing files line by line
#
print "# --- checking ---\n" if $dbg;
$lineno = 0;
our( $asmline, $disline );
while( defined( $asmline = <ASM> ) ){
    $disline = <DIS>;
    ++$lineno;
    last if $lineno eq $firstbadline; # bail out where errors begin
    ok( $asmline eq $disline, $descr[$lineno] );
    printf "# %5d %s\n", $lineno, $asmline if $dbg;
}
close( ASM );
close( DIS );

__END__
