package B::C::Section;
use strict;

# use warnings

use B::C::Debug ();
my %sections;

sub new {
    my ( $class, $section, $symtable, $default ) = @_;

    my $self = bless {
        'name'     => $section,
        'symtable' => $symtable,
        'default'  => $default,
        'values'   => [],
    }, $class;
    $sections{$section} = $self;

    # if sv add a dummy sv_arenaroot to support global destruction
    if ( $section eq 'sv' ) {
        $self->add("NULL, 0, SVTYPEMASK|0x01000000, {0}");    # SVf_FAKE
        $self->{'dbg'}->[0] = "PL_sv_arenaroot";
    }

    return $self;
}

sub add {
    my $self      = shift;
    my @list      = @_;
    my $add_stack = 'B::C::Save'->can('_caller_comment');
    if ( $list[-1] && ref $add_stack ) {
        my $add = $add_stack->();
        $list[-1] .= qq{\n} . $add if length $add;
    }
    push( @{ $self->{'values'} }, @list );

    # return its position in the list (first one will be 0), avoid to call index just after in most cases
    return $self->index();
}

# simple add using sprintf: avoid boilerplates
sub sadd {
    my ( $self, $pattern, @args ) = @_;
    return $self->add( sprintf( $pattern, @args ) );
}

# simple update using sprintf: avoid boilerplates
sub supdate {
    my ( $self, $row, $pattern, @args ) = @_;
    return $self->update( $row, sprintf( $pattern, @args ) );
}

sub update {
    my ( $self, $row, $value, $void ) = @_;
    die "Can only update one single entry" if defined $void;
    die "Element does not exists" if $row > $self->index;

    $self->{'values'}->[$row] = $value;

    return;
}

sub supdate_field {
    my ( $self, $row, $field, $pattern, @args ) = @_;
    return $self->update_field( $row, $field, sprintf( $pattern, @args ) );
}

=pod

update_field: update a single value from an existing line

=cut

sub update_field {
    my ( $self, $row, $field, $value, $void ) = @_;
    die "Need to call with row, field, value" unless defined $value;
    die "Extra argument after value" if defined $void;

    my $line   = $self->get($row);
    my @fields = _field_split($line);    # does not handle comma in comments

    die "Invalid field id $field" if $field > $#fields;
    $fields[$field] = $value;
    $line = join ',', @fields;           # update line

    return $self->update( $row, $line );
}

sub _field_split {
    my $to_split = shift;
    my @list = split( ',', $to_split );
    my @ok;
    my ( $count_open, $count_close );
    my $str;
    my $reset = sub { $str = '', $count_open = $count_close = 0 };
    $reset->();
    foreach my $next (@list) {
        $str .= ',' if length $str;
        $str .= $next;
        my $snext = $next;
        $snext =~ s{"[^"]+"}{""}g;    # remove weird content inside double quotes
        $count_open  += $snext =~ tr/(//;
        $count_close += $snext =~ tr/)//;

        #warn "$count_open vs $count_close: $str";
        if ( $count_close == $count_open ) {
            push @ok, $str;
            $reset->();
        }
    }
    die "Cannot split correctly '$to_split' (some leftover='$str')" if length $str;

    return @ok;
}

sub get {
    my ( $self, $row ) = @_;

    return $self->{'values'}->[$row];
}

sub get_field {
    my ( $self, $row, $field, $void ) = @_;

    die "Need to call with row, field" unless defined $field;
    die "Extra argument after value" if defined $void;

    my $line   = $self->get($row);
    my @fields = _field_split($line);    # does not handle comma in comments

    die "Invalid field id $field" if $field > $#fields;

    return $fields[$field];
}

sub get_fields {
    my ( $self, $row ) = @_;

    my $line = $self->get($row);
    return split( qr/\s*,\s*/, $line );
}

sub remove {    # should be rename pop or remove last
    my $self = shift;
    pop @{ $self->{'values'} };
}

sub name {
    return shift->{'name'};
}

sub symtable {
    return shift->{'symtable'};
}

sub default {
    return shift->{'default'};
}

sub index {
    my $self = shift;
    return scalar( @{ $self->{'values'} } ) - 1;
}

sub typename {
    my $self     = shift;
    my $name     = $self->name;
    my $typename = uc($name);
    $typename = 'UNOP_AUX'  if $typename eq 'UNOPAUX';
    $typename = 'MyPADNAME' if $typename eq 'PADNAME';
    $typename = 'SHARED_HE' if $typename eq 'SHAREDHE';

    return $typename;
}

sub comment_common {
    my $self = shift;
    return $self->comment( B::C::opsect_common(), ', ', @_ );
}

sub comment {
    my $self = shift;

    my @comments = grep { defined $_ } @_;
    $self->{'comment'} = join( "", @comments ) if @comments;

    return $self->{'comment'};
}

# add debugging info - stringified flags on -DF
my $debug_flags;

sub debug {

    # disable the sub when unused
    if ( !defined $debug_flags ) {
        $debug_flags = B::C::Debug::debug('flags') ? 1 : 0;
        if ( !$debug_flags ) {

            # Scoped no warnings without loading the module.
            local $^W;
            BEGIN { ${^WARNING_BITS} = 0; }
            *debug = sub { };

            return;
        }
    }

    # debug
    my ( $self, $op ) = @_;

    my $dbg = ref $op && $op->can('flagspv') ? $op->flagspv : undef;
    $self->{'dbg'}->[ $self->index ] = $dbg if $dbg;

    return;
}

sub output {
    my ( $self, $format ) = @_;
    my $sym     = $self->symtable;    # This should always be defined. see new
    my $default = $self->default;

    my $i = 0;
    my $dodbg = 1 if B::C::Debug::debug('flags') and $self->{'dbg'};
    if ( $self->name eq 'sv' ) {      #fixup arenaroot refcnt
        my $len = scalar @{ $self->{'values'} };
        $self->{'values'}->[0] =~ s/^NULL, 0/NULL, $len/;
    }

    my $return_string = '';

    foreach ( @{ $self->{'values'} } ) {
        my $val = $_;                 # Copy so we don't overwrite on successive calls.
        my $dbg = "";
        my $ref = "";
        if ( $val =~ m/(s\\_[0-9a-f]+)/ ) {
            if ( !exists( $sym->{$1} ) and $1 ne 's\_0' ) {
                $ref = $1;
                $B::C::unresolved_count++;
                B::C::Debug::verbose( "Warning: unresolved " . $self->name . " symbol $ref" );
            }
        }
        $val =~ s{(s\\_[0-9a-f]+)}{ exists($sym->{$1}) ? $sym->{$1} : $default; }ge;
        if ( $dodbg and $self->{'dbg'}->[$i] ) {
            $dbg = " /* " . $self->{'dbg'}->[$i] . " " . $ref . " */";
        }

        {
            # Scoped no warnings without loading the module.
            local $^W;
            BEGIN { ${^WARNING_BITS} = 0; }
            $return_string .= sprintf( $format, $val, $self->name, $i, $ref, $dbg );
        }

        ++$i;
    }

    return $return_string;
}

1;
