package HBase::JSONRest;

use strict;
use warnings;

use 5.010;

use HTTP::Tiny;

use URI::Escape;

use MIME::Base64;
use JSON::XS qw(decode_json encode_json);

use Time::HiRes qw(gettimeofday time);

use Data::Dumper;

our $VERSION = "0.1";

my %INFO_ROUTES = (
    version => '/version',
    list    => '/',
);

################
# Class Methods
#
sub new {

    my $class = shift;
    $class = ref $class if ref $class;

    my $params = (ref $_[0] eq 'HASH') ? shift : {@_};

    my $service_host = delete $params->{service_host}
        || die "Need a service_host";

    my $port = delete $params->{port} || 8080;

    my $self;

    $self->{service} = "http://$service_host:$port";
    $self->{host} = $service_host;
    $self->{port} = $port;

    return bless ($self, $class);

}


###################
# Instance Methods
#

# -------------------------------------------------------------------------
#
# list of tables
#
sub list {
    my $self = shift;

    my $uri = $self->{service} . $INFO_ROUTES{list};

    my $http = HTTP::Tiny->new();

    my $rs = $http->get($uri, {
         headers => {
             'Accept' => 'application/json',
         }
    });

    return( wantarray
         ? (undef, _extract_error_tiny( $rs ))
         : undef
    ) unless $rs->{success};

    my $response = decode_json($rs->{content});

    my @tables = ();
    foreach my $table (@{$response->{table}}) {
        my $table_name = $table->{name};
        push @tables, {name => $table_name};
    }

    return \@tables;
}

# -------------------------------------------------------------------------
#
# get hbase rest version
#
sub version {
    my $self = shift;

    my $uri = $self->{service} . $INFO_ROUTES{version};

    my $http = HTTP::Tiny->new();

    my $rs = $http->get($uri, {
         headers => {
             'Accept' => 'application/json',
         }
    });

    return( wantarray
         ? (undef, _extract_error_tiny( $rs ))
         : undef
    ) unless $rs->{success};

    my $response = decode_json($rs->{content});

    my $version = $response->{REST} ? $response->{REST} : undef;

    return { hbase_rest_version => $version };
}

# -------------------------------------------------------------------------
#
# get
#
# usage:
#   my ($records, $err) = $hbase->get(
#        table   => 'table_name',
#        where   => {
#            key_begins_with => "key_prefix"
#        },
#    );
sub get {
    my $self = shift;
    my $params = (ref $_[0] eq 'HASH') ? shift : {@_};

    my $rows = $self->_get_tiny($params);

    return $rows;
}

# _get_tiny
sub _get_tiny {

    my $self = shift;
    my $query = (ref $_[0] eq 'HASH') ? shift : {@_};

    my $table = $query->{table};

    my $route;
    if ($query->{where}->{key_equals}) {
        my $key = $query->{where}->{key_equals};
        $route = '/' . $table . '/' . uri_escape($key);
    }
    else {
        my $part_of_key = $query->{where}->{key_begins_with};
        $route = '/' . $table . '/' . uri_escape($part_of_key . '*');
    }

    my $uri = $self->{service} . $route;

    my $http = HTTP::Tiny->new();

    my $rs = $http->get($uri, {
        headers => {
            'Accept' => 'application/json',
        }
    });

    return( wantarray
        ? (undef, _extract_error_tiny( $rs ))
        : undef
    ) unless $rs->{success};

    my $response = decode_json($rs->{content});

    my @rows = ();
    foreach my $row (@{$response->{Row}}) {

        my $key = decode_base64($row->{key});
        my @cols = ();

        foreach my $c (@{$row->{Cell}}) {
            my $name = decode_base64($c->{column});
            my $value = decode_base64($c->{'$'});
            my $ts = $c->{timestamp};
            push @cols, {name => $name, value => $value, timestamp => $ts};
        }
        push @rows, {row => $key, columns => \@cols};
    }

    return \@rows;
}

# -------------------------------------------------------------------------
#
# put:
#
# IN: HASH => {
#   table   => $table,
#   changes => [ # array of hashes, where each hash is one row
#       ...,
#       {
#          row_key   => "$row_key",
#          row_cell => [
#              { column => 'family:name', value => 'value' },
#              ...,
#              { column => 'family:name', value => 'value' },
#         ],
#      },
#      ...
#   ]
# }
#
# OUT: result flag
sub put {
    my $self    = shift;
    my $command = (ref $_[0] eq 'HASH') ? shift : {@_};

    # at least one valid record
    unless ($command->{table} && $command->{changes}->[0]->{row_key} && $command->{changes}->[0]->{row_cells}) {
        die q/Must provide required parameters:
            IN: HASH => {
               table   => $table,
               changes => [
                   ...,
                   {
                      row_key   => "$row_key",
                      row_cells => [
                          { column => 'family:name', value => 'value' },
                          ...
                          { column => 'family:name', value => 'value' },
                     ],
                  },
                  ...
               ]
             };
        /;
    }

    my $table   = $command->{table};

    # build JSON:
    my $JSON_Command .= '{"Row":[';
    my @sorted_json_row_changes = ();
    foreach my $row_change (@{$command->{changes}}) {

        my $row_cell_changes   = $row_change->{row_cells};

        my $rows = [];
        my $row_change_formated = { Row => $rows };
        my $row_cell_changes_formated = {};

        my $ts = int(gettimeofday * 1000);

        # hbase wants keys in sorted order; it wont work otherwise;
        # more specificaly, the special key '$' has to be at the end;
        my $sorted_json_row_change =
            q|{"key":"|
            . encode_base64($row_change->{row_key}, '')
            . q|","Cell":[|
        ;

        my @sorted_json_cell_changes = ();
        foreach my $cell_change (@$row_cell_changes) {

            my  $sorted_json_cell_change =
                    '{'
                        . '"timestamp":"'
                        . $ts
                        . '",'
                        . '"column":"'
                        . encode_base64($cell_change->{column}, '')
                        . '",'
                        . '"$":"'
                        . encode_base64($cell_change->{value}, '')
                    . '"}'
            ;

            push @sorted_json_cell_changes, $sorted_json_cell_change;

        } # next Cell

        $sorted_json_row_change .= join(",", @sorted_json_cell_changes);
        $sorted_json_row_change .= ']}';

        push @sorted_json_row_changes, $sorted_json_row_change;

    } # next Row

    $JSON_Command .= join(",", @sorted_json_row_changes);
    $JSON_Command .= ']}';

    my $route = '/' . uri_escape($table) . '/false-row-key';
    my $uri = $self->{service} . $route;

    my $http = HTTP::Tiny->new();

    my $rs = $http->request('PUT', $uri, {
        content => $JSON_Command,
        headers => {
            'Accept'       => 'application/json',
            'content-type' => 'application/json'
        },
    });

    return( wantarray
        ? (undef, _extract_error_tiny( $rs ))
        : undef
    ) unless $rs->{success};

}

# -------------------------------------------------------------------------
# parse error
#
sub _extract_error_tiny {
    my $res = shift;

    return if $res->{success};
    return if $res->{status} == 404;
    my $msg = $res->{reason};

    my ($exception, $info) = $msg =~ m{\.([^\.]+):(.*)$};
    if ($exception) {
        $exception =~ s{Exception$}{};
    } else {
        $exception = 'SomeOther - not set?';
        $info = $msg || $res->{status} || Dumper($res);
    }

    return { type => $exception, info => $info };

}

1;

__END__

=encoding utf8

=head1 NAME

HBase::JSONRest - Simple REST client for HBase

=head1 SYNOPSIS

A simple get request:

    my $hbase = HBase::JSONRest->new(service_host => $hostname);

    my ($records, $err) = $hbase->get(
        table   => 'table_name',
        where   => {
            key_begins_with => "key_prefix"
        },
    );

A simple put request:

    # array of hashes, where each hash is one row
    my $rows = [
        ...
        {
            row_key => "$row_key",

            # cells: array of hashes where eash hash is one cell
            row_cells => [
              { column => "$family_name:$colum_name", value => "$value" },
            ],
       },
       ...
    ];

    my ($res,$err) = $hbase->put(
        table   => $table_name,
        changes => $rows
    );

=head1 DESCRIPTION

A simple rest client for HBase.

=head1 METHODS

=head2 get
Scans a table by key prefix or exact key match depending on options passed:

    # scan by key prefix:
    my ($records,$err) = $hbase->get(
        table       => $table_name,
        where       => {
            key_begins_with => "$key_prefix"
        },
    );

    # exact match:
    my ($records,$err) = $hbase->get(
        table       => $table_name,
        where       => {
            key_equals => "$key"
        },
    );

=head2 put
Inserts one or multiple rows. If a key allready exists then depending
on if HBase versioning is on, the record will be updated (versioning is off)
or new version will be inserted (versioning is on)

    # multiple rows
    my $rows = [
        ...
        {
            row_key => "$row_key",

            # cells: array of hashes where eash hash is one cell
            row_cells => [
              { column => "$family_name:$colum_name", value => "$value" },
            ],
       },
       ...
    ];

    my ($res,$err) = $hbase->put(
        table   => $table_name,
        changes => $rows
    );

    # single row - basically the same as multiple rows, but
    # the rows array has just one elements
    my $rows = [
        {
            row_key => "$row_key",

            # cells: array of hashes where eash hash is one cell
            row_cells => [
              { column => "$family_name:$colum_name", value => "$value" },
            ],
       },
    ];

    my ($res,$err) = $hbase->put(
        table   => $table_name,
        changes => $rows
    );

=head2 version
Current version: 0.1

=head1 AUTHOR

bdevetak - Bosko Devetak (cpan:BDEVETAK) <bosko.devetak@gmail.com>

=head1 CONTRIBUTORS

theMage - (cpan:NEVES) <mailto:themage@magick-source.net>

=head1 COPYRIGHT

Copyright (c) 2014 the HBase::JSONRest L</AUTHOR> and L</CONTRIBUTORS>
as listed above.

=head1 LICENSE

This library is free software and may be distributed under the same terms
as perl itself. See L<http://dev.perl.org/licenses/>.

=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

=cut
