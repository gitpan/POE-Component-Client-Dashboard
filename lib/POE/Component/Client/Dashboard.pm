package POE::Component::Client::Dashboard;
use strict;
use warnings;

=head1 NAME

POE::Component::Client::Dashboard -- Dashboard cluepacket component

=head1 SYNOPSIS

	use POE
	use POE::Component::Client::Dashboard;

	POE::Component::Client::Dashboad->spawn (
		alias => 'clue',
		host => 'localhost',
		port => 5913,
		frontend => 'app name');

	...

	# send this when your app displays an url
	my @clues = ({Type => 'url', Relevance => 10, content => $uri});
	$kernel->post ('clue', send_clue => 'error_callback', $uri, 1, \@clues);

=head1 DESCRIPTION

With this component, you can send cluepackets to a Dashboard server, so it
can learn what your application is up to, and try to display information
relevant to your current task.

=cut

sub DEBUG      () { 0 }
our $VERSION = '0.02';

use POE qw(
   Wheel::SocketFactory
   Wheel::ReadWrite
   Driver::SysRW
   Filter::Stream
   Component::Client::DNS
);

use XML::Simple;

sub REQ_POSTBACK      () { 0 }
sub REQ_WHEEL         () { 1 }
sub REQ_REQUEST       () { 2 }
sub REQ_RESPONSE      () { 3 }
sub REQ_TIMER         () { 4 }
sub REQ_START_TIME    () { 5 }

# Unique request ID, independent of wheel and timer IDs.

my $request_seq = 0;

=head1 CONSTRUCTOR

=head2 spawn (%options)

creates a new POE::Component::Client::Dashboard session. It takes several
parameters:

=over 4

=item frontend (REQUIRED)

An string to identify your app to Dashboard. Usually the name of your
application. 

=item alias (OPTIONAL)

The session alias you want to use

=item host (OPTIONAL)

The host of the Dashboard server to connect to. Defaults to localhost

=item port (OPTIONAL)

The port of the Dashboard server to connect to. Defaults to 5913

=back

=cut

sub spawn {
   my ($class, %params) = @_;

   return undef unless (defined $params{frontend});

   my $alias = $params{alias};
   $params{alias} = $alias = 'cluewee' unless defined $alias and length $alias;

   my $timeout = $params{timeout};
   $params{timeout} = $timeout = 180 unless defined $timeout and $timeout >= 0;

   my $host = $params{host};
   $params{host} = 'localhost' unless defined $host and length $host;

   my $port = $params{port};
   $params{port} = 5913 unless (defined $port and $port > 0);

   # Start a DNS resolver for this agent
   POE::Component::Client::DNS->spawn (
	 Alias   => "poco_${alias}_resolver",
	 Timeout => $timeout);

   POE::Session->create (
      inline_states => {
	 _start  => \&poco_weeble_start,
	_stop   => \&poco_weeble_stop,

	 # Public interface.
	 send_clue => \&poco_weeble_request,

	 # Net::DNS interface.
	 got_dns_response  => \&poco_weeble_dns_answer,
	 do_connect        => \&poco_weeble_do_connect,

	 # SocketFactory interface.
	 got_connect_done  => \&poco_weeble_connect_ok,
	 got_connect_error => \&poco_weeble_connect_error,

	 # ReadWrite interface.
	 got_socket_flush  => \&poco_weeble_io_flushed,
	 got_socket_error  => \&poco_weeble_io_error,

	 # I/O timeout.
	 got_timeout       => \&poco_weeble_timeout,
      },
      heap => \%params,
   );

   undef;
}

sub poco_weeble_start {
   my ($kernel, $heap) = @_[KERNEL, HEAP];

   $kernel->alias_set($heap->{alias});
}

#------------------------------------------------------------------------------

sub poco_weeble_stop {
   my $heap = shift;
   delete $heap->{request};

   DEBUG and warn "weeble stopped.\n";
}

=head1 EVENTS

=head2 send_clue (error_callback, context, is_focused, [clues]);

Sends a clue to the Dashboard server. The error_callback parameter is
the name of an event in the calling session that will receive a postback
style call when an error occurs.

context is a unique identifier for the clue context. For example, if
you were a browser, you could use the url of the web page.

is_focused is a boolean to let Dashboard know whether the user is
currently working with the context. So in the browser example whether
the clue is for the tab currently in view or not

clues is a listref of clue hashrefs, which have the following structure:

	{
		Type => [string; see dashboard docs for useful values],
		Relevance => [integer; relevancy rating from 1-10],
		content => [the value of the clue]
	}

=cut

sub poco_weeble_request {
   my ( $kernel, $heap, $sender,
	$response_event, $context, $is_focused, $clues
      ) = @_[KERNEL, HEAP, SENDER, ARG0, ARG1, ARG2, ARG3];

   my $cluepacket = {
      Frontend => [$heap->{frontend}],
      Context => [$context],
      Focused => [($is_focused ? "True" : "False")],
      Clue => $clues
   };
   my $xml_clue = XMLout ($cluepacket, rootname => 'CluePacket');
   DEBUG && print $xml_clue;

   # Get a unique request ID.
   my $request_id = ++$request_seq;

   # Build the request.
   my $request = [
      $sender->postback( $response_event, $xml_clue ),	 # REQ_POSTBACK
      undef,						 # REQ_WHEEL
      $xml_clue,					 # REQ_REQUEST
      undef,						 # REQ_RESPONSE
      undef,						 # REQ_TIMER
      time(),						 # REQ_START_TIME
   ];

   my $host = $heap->{host};
   # -><- Should probably check for IPv6 addresses here, too.
   if (exists $heap->{resolve}->{$host}) {
      DEBUG and warn "DNS: $host is piggybacking on a pending lookup.\n";
      push @{$heap->{resolve}->{$host}}, $request_id;
   } else {
      DEBUG and warn "DNS: $host is being looked up in the background.\n";
      $heap->{resolve}->{$host} = [ $request_id ];
      my $my_alias = $heap->{alias};
      $kernel->post( "poco_${my_alias}_resolver" =>
		     resolve => got_dns_response => $host => "A", "IN"
		   );
   }
   $heap->{request}->{$request_id} = $request;
}

sub poco_weeble_dns_answer {
   my ($kernel, $heap) = @_[KERNEL, HEAP];
   my $request_address = $_[ARG0]->[0];
   my $response_object = $_[ARG1]->[0];
   my $response_error  = $_[ARG1]->[1];

   my $requests = delete $heap->{resolve}->{$request_address};

   DEBUG and warn $request_address;

   # No requests are on record for this lookup.
   die unless defined $requests;

   # No response.
   unless (defined $response_object) {
      foreach my $request_id (@$requests) {
	 my $request = delete $heap->{request}->{$request_id};
	 _post_error($request, $response_error);
      }
      return;
   }

   # A response!
   foreach my $answer ($response_object->answer()) {
      next unless $answer->type eq "A";

      DEBUG and
	 warn "DNS: $request_address resolves to ", $answer->rdatastr(), "\n";

      foreach my $request_id (@$requests) {
	 $kernel->yield( do_connect => $request_id, $answer->rdatastr );
      }

      # Return after the first good answer.
      return;
   }

   # Didn't return here.  No address record for the host?
   foreach my $request_id (@$requests) {
      my $request = delete $heap->{request}->{$request_id};
      _post_error($request, "Host has no address.");
   }
}

#------------------------------------------------------------------------------

sub poco_weeble_do_connect {
   my ($kernel, $heap, $request_id, $address) = @_[KERNEL, HEAP, ARG0, ARG1];

   my $request = $heap->{request}->{$request_id};

   # Create a socket factory.
   my $socket_factory =
      $request->[REQ_WHEEL] =
      POE::Wheel::SocketFactory->new
      ( RemoteAddress => $address,
	RemotePort    => $heap->{port},
	SuccessEvent  => 'got_connect_done',
	FailureEvent  => 'got_connect_error',
      );

   # Create a timeout timer.
   $request->[REQ_TIMER] = $kernel->delay_set (
      'got_timeout',
      $heap->{timeout} - (time() - $request->[REQ_START_TIME]),
      $request_id
   );

# Cross-reference the wheel and timer IDs back to the request.
   $heap->{timer_to_request}->{$request->[REQ_TIMER]} = $request_id;
   $heap->{wheel_to_request}->{$socket_factory->ID()} = $request_id;

   DEBUG and
      warn( "wheel ", $socket_factory->ID,
	    " is connecting to $heap->{host} : $heap->{port} ...\n"
	  );
}

#------------------------------------------------------------------------------

sub poco_weeble_connect_ok {
   my ($heap, $socket, $wheel_id) = @_[HEAP, ARG0, ARG3];

   DEBUG and warn "wheel $wheel_id connected ok...\n";

   # Remove the old wheel ID from the look-up table.
   my $request_id = delete $heap->{wheel_to_request}->{$wheel_id};
   die unless defined $request_id;

   my $request = $heap->{request}->{$request_id};

   # Make a ReadWrite wheel to interact on the socket.
   my $new_wheel = POE::Wheel::ReadWrite->new
      ( Handle       => $socket,
	Driver       => POE::Driver::SysRW->new(),
	Filter       => POE::Filter::Stream->new(),
	FlushedEvent => 'got_socket_flush',
	ErrorEvent   => 'got_socket_error',
      );

   # Add the new wheel ID to the lookup table.
   $heap->{wheel_to_request}->{ $new_wheel->ID() } = $request_id;

   # Switch wheels.  This is a bit cumbersome, but it works around a
   # bug in older versions of POE.
   undef $request->[REQ_WHEEL];
   $request->[REQ_WHEEL] = $new_wheel;

   # Put the request.  HTTP::Request's as_string() method isn't quite
   # right.  It uses the full URL on the request line, so we have to
   # put the request in pieces.
   my $xml_clue = $request->[REQ_REQUEST];
   $request->[REQ_WHEEL]->put( $xml_clue );
}


sub poco_weeble_connect_error {
   my ($kernel, $heap, $operation, $errnum, $errstr, $wheel_id) =
      @_[KERNEL, HEAP, ARG0..ARG3];

   DEBUG and
      warn "wheel $wheel_id encountered $operation error $errnum: $errstr\n";

   # Drop the wheel and its cross-references.
   my $request_id = delete $heap->{wheel_to_request}->{$wheel_id};
   die unless defined $request_id;

   my $request = delete $heap->{request}->{$request_id};

   my $alarm_id = $request->[REQ_TIMER];
   if (delete $heap->{timer_to_request}->{ $alarm_id }) {
      $kernel->alarm_remove( $alarm_id );
   }

   # Post an error response back to the requesting session.
   _post_error($request, "$operation error $errnum: $errstr");
}

sub poco_weeble_timeout {
   my ($kernel, $heap, $request_id) = @_[KERNEL, HEAP, ARG0];

   DEBUG and warn "request $request_id timed out\n";

   # Drop the wheel and its cross-references.
   my $request = delete $heap->{request}->{$request_id};

   if (defined $request->[REQ_WHEEL]) {
      delete $heap->{wheel_to_request}->{ $request->[REQ_WHEEL]->ID() };
   }

   # No need to remove the alarm here because it's already gone.
   delete $heap->{timer_to_request}->{ $request->[REQ_TIMER] };

   # Post an error response back to the requesting session.
   _post_error($request, "Request timed out.");
}

sub poco_weeble_io_flushed {
   my ($kernel, $heap, $wheel_id) = @_[KERNEL, HEAP, ARG0];

   DEBUG and warn "wheel $wheel_id flushed its request...\n";

   # Hang up on purpose.
   my $request_id = delete $heap->{wheel_to_request}->{$wheel_id};
   die unless defined $request_id;
   my $request = delete $heap->{request}->{$request_id};

   # Stop the timeout timer for this wheel, too.
   my $alarm_id = $request->[REQ_TIMER];
   if (delete $heap->{timer_to_request}->{$alarm_id}) {
      $kernel->alarm_remove( $alarm_id );
   }
}

sub poco_weeble_io_error {
   my ($kernel, $heap, $operation, $errnum, $errstr, $wheel_id) =
      @_[KERNEL, HEAP, ARG0..ARG3];

   DEBUG and
      warn "wheel $wheel_id encountered $operation error $errnum: $errstr\n";

   # Drop the wheel.
   my $request_id = delete $heap->{wheel_to_request}->{$wheel_id};
   my $request = delete $heap->{request}->{$request_id};

   # Stop the timeout timer for this wheel, too.
   my $alarm_id = $request->[REQ_TIMER];
   if (delete $heap->{timer_to_request}->{$alarm_id}) {
      $kernel->alarm_remove( $alarm_id );
   }

   # If there was a non-zero error, then something bad happened.  Post
   # an error response back.
   if ($errnum) {
      _post_error($request, "$operation error $errnum: $errstr" );
      return;
   }
}

# Post an error message.  This is not a POE function.

sub _post_error {
   my ($request, $message) = @_;

   $request->[REQ_POSTBACK]->($message);
}

=head1 AUTHOR & COPYRIGHTS

POE::Component::Client::Dashboard is based on POE::Component::Client::HTTP,
which is written by Rocco Caputo and licenced under the same terms as Perl.

All original code is Copyright 2003 by Martijn van Beers, and licenced
under the GNU GPL licence.

All comments on POE::Component::Client::Dashboard should go to
Martijn van Beers via martijn@cpan.org.

=cut

1;
