package Type::Params;

use 5.006001;
use strict;
use warnings;

BEGIN {
	if ( $] < 5.008 ) { require Devel::TypeTiny::Perl56Compat }
}

BEGIN {
	$Type::Params::AUTHORITY = 'cpan:TOBYINK';
	$Type::Params::VERSION   = '1.014000';
}

$Type::Params::VERSION =~ tr/_//d;

use B qw();
use Eval::TypeTiny;
use Scalar::Util qw(refaddr);
use Error::TypeTiny;
use Error::TypeTiny::Assertion;
use Error::TypeTiny::WrongNumberOfParameters;
use Types::Standard ();
use Types::TypeTiny ();

require Exporter::Tiny;
our @ISA = 'Exporter::Tiny';

our @EXPORT = qw( compile compile_named );
our @EXPORT_OK =
	qw( multisig validate validate_named compile_named_oo Invocant wrap_subs wrap_methods ArgsObject );
	
sub english_list {
	require Type::Utils;
	goto \&Type::Utils::english_list;
}

my $QUOTE = \&B::perlstring;

{
	my $Invocant;
	
	sub Invocant () {
		$Invocant ||= do {
			require Type::Tiny::Union;
			require Types::Standard;
			'Type::Tiny::Union'->new(
				name             => 'Invocant',
				type_constraints => [
					Types::Standard::Object(),
					Types::Standard::ClassName(),
				],
			);
		};
	} #/ sub Invocant
	
	my $ArgsObject;
	
	sub ArgsObject (;@) {
		$ArgsObject ||= do {
			require Types::Standard;
			'Type::Tiny'->new(
				name                 => 'ArgsObject',
				parent               => Types::Standard::Object(),
				constraint           => q{ ref($_) =~ qr/^Type::Params::OO::/ },
				constraint_generator => sub {
					my $param = Types::Standard::assert_Str( shift );
					sub { defined( $_->{'~~caller'} ) and $_->{'~~caller'} eq $param };
				},
				inline_generator => sub {
					my $param  = shift;
					my $quoted = $QUOTE->( $param );
					sub {
						my $var = pop;
						return (
							Types::Standard::Object()->inline_check( $var ),
							sprintf( q{ ref(%s) =~ qr/^Type::Params::OO::/ }, $var ),
							sprintf(
								q{ do { use Scalar::Util (); Scalar::Util::reftype(%s) eq 'HASH' } }, $var
							),
							sprintf(
								q{ defined((%s)->{'~~caller'}) && ((%s)->{'~~caller'} eq %s) }, $var, $var,
								$quoted
							),
						);
					};
				},
			);
		};
		
		@_ ? $ArgsObject->parameterize( @{ $_[0] } ) : $ArgsObject;
	} #/ sub ArgsObject (;@)
	
	if ( $] ge '5.014' ) {
		&Scalar::Util::set_prototype( $_, ';$' ) for \&ArgsObject;
	}
}

sub _mkslurpy {
	my ( $name, $type, $tc, $i ) = @_;
	$name = 'local $_' if $name eq '$_';
	
	$type eq '@'
		? sprintf(
		'%s = [ @_[%d..$#_] ];',
		$name,
		$i,
		)
		: sprintf(
		'%s = (@_==%d and ref $_[%d] eq "HASH") ? +{ %%{$_[%d]} } : (($#_-%d)%%2)==0 ? do { return "Error::TypeTiny::WrongNumberOfParameters"->throw_cb($on_die, message => sprintf("Odd number of elements in %%s", %s)) } : +{ @_[%d..$#_] };',
		$name,
		$i + 1,
		$i,
		$i,
		$i,
		$QUOTE->( "$tc" ),
		$i,
		);
} #/ sub _mkslurpy

sub _mkdefault {
	my $param_options = shift;
	my $default;
	
	if ( exists $param_options->{default} ) {
		$default = $param_options->{default};
		if ( Types::Standard::is_ArrayRef( $default ) and not @$default ) {
			$default = '[]';
		}
		elsif ( Types::Standard::is_HashRef( $default ) and not %$default ) {
			$default = '{}';
		}
		elsif ( Types::Standard::is_Str( $default ) ) {
			$default = $QUOTE->( $default );
		}
		elsif ( Types::Standard::is_Undef( $default ) ) {
			$default = 'undef';
		}
		elsif ( not Types::TypeTiny::is_CodeLike( $default ) ) {
			Error::TypeTiny::croak(
				"Default expected to be string, coderef, undef, or reference to an empty hash or array"
			);
		}
	} #/ if ( exists $param_options...)
	
	$default;
} #/ sub _mkdefault

sub _deal_with_on_die {
	my $options = shift;
	if ( $options->{'on_die'} ) {
		return ( { '$on_die' => \$options->{'on_die'} }, '1;' );
	}
	return ( {}, 'my $on_die = undef;' );
}

sub _deal_with_head_and_tail {
	my $options = shift;
	$options->{arg_fudge_factor}      = 0;
	$options->{arg_fudge_factor_head} = 0;
	my @lines;
	my %env;
	
	for my $position ( qw/ head tail / ) {
		next unless defined $options->{$position};
		
		$options->{$position} =
			[ ( Types::Standard::Any ) x ( 0+ $options->{$position} ) ]
			if !ref $options->{$position};
			
		my $count = @{ $options->{$position} };
		$options->{arg_fudge_factor}      += $count;
		$options->{arg_fudge_factor_head} += $count if $position eq 'head';
		
		push @lines => (
			$position eq 'head'
			? "\@head = splice(\@_, 0, $count);"
			: "\@tail = splice(\@_, -$count);",
		);
		
		for my $i ( 0 .. $count - 1 ) {
			my $constraint = $options->{$position}[$i];
			$constraint = $options->{$position}[$i] = Types::Standard::Any
				if !ref $constraint && $constraint eq 1;
			Types::TypeTiny::assert_TypeTiny( $constraint );
			
			my $is_optional = 0;
			$is_optional += grep $_->{uniq} == Types::Standard::Optional->{uniq},
				$constraint->parents;
			Error::TypeTiny::croak( "The $position may not contain optional parameters" )
				if $is_optional;
				
			my $varname = sprintf( '$%s[%d]', $position, $i );
			my $display_var =
				$position eq 'head'
				? sprintf( '$_[%d]', $i )
				: sprintf( '$_[%d]', $i - $count );
				
			if ( $constraint->has_coercion and $constraint->coercion->can_be_inlined ) {
				push @lines, sprintf(
					'%s = do { %s };',
					$varname,
					$constraint->coercion->inline_coercion( $varname ),
				);
			}
			elsif ( $constraint->has_coercion ) {
				$env{ '@coerce_' . $position }[$i] = $constraint->coercion->compiled_coercion;
				push @lines, sprintf(
					'%s = $coerce_%s[%d]->(%s);',
					$varname,
					$position,
					$i,
					$varname,
				);
			} #/ elsif ( $constraint->has_coercion)
			
			undef $Type::Tiny::ALL_TYPES{ $constraint->{uniq} };
			$Type::Tiny::ALL_TYPES{ $constraint->{uniq} } = $constraint;
			
			if ( $constraint == Types::Standard::Any ) {
			
				# don't really need to check!
			}
			elsif ( $constraint->can_be_inlined ) {
				push @lines, sprintf(
					'(%s) or return Type::Tiny::_failed_check(%d, %s, %s, varname => %s, on_die => $on_die);',
					$constraint->inline_check( $varname ),
					$constraint->{uniq},
					$QUOTE->( $constraint ),
					$varname,
					$QUOTE->( $display_var ),
				);
			} #/ elsif ( $constraint->can_be_inlined)
			else {
				$env{ '@check_' . $position }[$i] = $constraint->compiled_check;
				push @lines, sprintf(
					'%s or return Type::Tiny::_failed_check(%d, %s, %s, varname => %s, on_die => $on_die);',
					sprintf( sprintf '$check_%s[%d]->(%s)', $position, $i, $varname ),
					$constraint->{uniq},
					$QUOTE->( $constraint ),
					$varname,
					$QUOTE->( $display_var ),
				);
			} #/ else [ if ( $constraint == Types::Standard::Any)]
		} #/ for my $i ( 0 .. $count...)
	} #/ for my $position ( qw/ head tail /)
	
	if ( @lines ) {
		unshift @lines => sprintf(
			'return "Error::TypeTiny::WrongNumberOfParameters"->throw_cb($on_die, "Not enough parameters to satisfy required head and tail of parameter list") if @_ < %d;',
			$options->{arg_fudge_factor},
		);
		unshift @lines, 'my (@head, @tail);';
	}
	
	\%env, @lines;
} #/ sub _deal_with_head_and_tail

sub compile {
	my ( @code, %env );
	
	push @code, '#placeholder', '#placeholder';    # @code[0,1]
	
	my %options;
	while ( ref( $_[0] ) eq "HASH" && !$_[0]{slurpy} ) {
		%options = ( %options, %{ +shift } );
	}
	
	my $arg        = -1;
	my $saw_slurpy = 0;
	my $min_args   = 0;
	my $max_args   = 0;
	my $saw_opt    = 0;
	
	my $return_list = '@_';
	$code[0] = 'my (%tmp, $tmp);';
	PARAM: for my $param ( @_ ) {
		if ( Types::Standard::is_HashRef( $param ) ) {
			$code[0] = 'my (@R, %tmp, $tmp, $dtmp);';
			$return_list = '@R';
			last PARAM;
		}
		elsif ( not Types::Standard::is_Bool( $param ) ) {
			if ( $param->has_coercion ) {
				$code[0] = 'my (@R, %tmp, $tmp, $dtmp);';
				$return_list = '@R';
				last PARAM;
			}
		}
	} #/ PARAM: for my $param ( @_ )

	{
		my ( $extra_env, @extra_lines ) = _deal_with_on_die( \%options );
		if ( @extra_lines ) {
			$code[0] .= join '', @extra_lines;
			%env = ( %$extra_env, %env );
		}
	}

	{
		my ( $extra_env, @extra_lines ) = _deal_with_head_and_tail( \%options );
		if ( @extra_lines ) {
			push @code, @extra_lines;
			%env         = ( %$extra_env, %env );
			$return_list = '(@head, @R, @tail)';
		}
	}
	
	my $for =
		$options{subname}
		|| [ caller( 1 + ( $options{caller_level} || 0 ) ) ]->[3]
		|| '__ANON__';
		
	my @default_indices;
	my @default_values;
	
	while ( @_ ) {
		++$arg;
		my $constraint = shift;
		my $is_optional;
		my $really_optional;
		my $is_slurpy;
		my $varname;
		
		my $param_options = {};
		$param_options = shift
			if Types::Standard::is_HashRef( $_[0] ) && !exists $_[0]{slurpy};
		my $default = _mkdefault( $param_options );
		
		if ( $param_options->{optional} or defined $default ) {
			$is_optional = 1;
		}
		
		if ( Types::Standard::is_Bool( $constraint ) ) {
			$constraint =
				$constraint
				? Types::Standard::Any
				: Types::Standard::Optional [Types::Standard::Any];
		}
		
		if ( Types::Standard::is_HashRef( $constraint )
			and exists $constraint->{slurpy} )
		{
			$constraint = Types::TypeTiny::to_TypeTiny(
				$constraint->{slurpy}
					or Error::TypeTiny::croak( "Slurpy parameter malformed" )
			);
			push @code,
				$constraint->is_a_type_of( Types::Standard::Dict )
				? _mkslurpy( '$_', '%', $constraint => $arg )
				: $constraint->is_a_type_of( Types::Standard::Map )
				? _mkslurpy( '$_', '%', $constraint => $arg )
				: $constraint->is_a_type_of( Types::Standard::Tuple )
				? _mkslurpy( '$_', '@', $constraint => $arg )
				: $constraint->is_a_type_of( Types::Standard::HashRef )
				? _mkslurpy( '$_', '%', $constraint => $arg )
				: $constraint->is_a_type_of( Types::Standard::ArrayRef )
				? _mkslurpy( '$_', '@', $constraint => $arg )
				: Error::TypeTiny::croak( "Slurpy parameter not of type HashRef or ArrayRef" );
			$varname = '$_';
			$is_slurpy++;
			$saw_slurpy++;
		} #/ if ( Types::Standard::is_HashRef...)
		else {
			Error::TypeTiny::croak( "Parameter following slurpy parameter" ) if $saw_slurpy;
			
			$is_optional += grep $_->{uniq} == Types::Standard::Optional->{uniq},
				$constraint->parents;
			$really_optional =
				$is_optional
				&& $constraint->parent
				&& $constraint->parent->{uniq} eq Types::Standard::Optional->{uniq}
				&& $constraint->type_parameter;
				
			if ( ref $default ) {
				$env{'@default'}[$arg] = $default;
				push @code, sprintf(
					'$dtmp = ($#_ < %d) ? $default[%d]->() : $_[%d];',
					$arg,
					$arg,
					$arg,
				);
				$saw_opt++;
				$max_args++;
				$varname = '$dtmp';
			} #/ if ( ref $default )
			elsif ( defined $default ) {
				push @code, sprintf(
					'$dtmp = ($#_ < %d) ? %s : $_[%d];',
					$arg,
					$default,
					$arg,
				);
				$saw_opt++;
				$max_args++;
				$varname = '$dtmp';
			} #/ elsif ( defined $default )
			elsif ( $is_optional ) {
				push @code, sprintf(
					'return %s if $#_ < %d;',
					$return_list,
					$arg,
				);
				$saw_opt++;
				$max_args++;
				$varname = sprintf '$_[%d]', $arg;
			} #/ elsif ( $is_optional )
			else {
				Error::TypeTiny::croak( "Non-Optional parameter following Optional parameter" )
					if $saw_opt;
				$min_args++;
				$max_args++;
				$varname = sprintf '$_[%d]', $arg;
			}
		} #/ else [ if ( Types::Standard::is_HashRef...)]
		
		if ( $constraint->has_coercion and $constraint->coercion->can_be_inlined ) {
			push @code, sprintf(
				'$tmp%s = %s;',
				( $is_optional ? '{x}' : '' ),
				$constraint->coercion->inline_coercion( $varname )
			);
			$varname = '$tmp' . ( $is_optional ? '{x}' : '' );
		}
		elsif ( $constraint->has_coercion ) {
			$env{'@coerce'}[$arg] = $constraint->coercion->compiled_coercion;
			push @code, sprintf(
				'$tmp%s = $coerce[%d]->(%s);',
				( $is_optional ? '{x}' : '' ),
				$arg,
				$varname,
			);
			$varname = '$tmp' . ( $is_optional ? '{x}' : '' );
		} #/ elsif ( $constraint->has_coercion)
		
		# unweaken the constraint in the cache
		undef $Type::Tiny::ALL_TYPES{ $constraint->{uniq} };
		$Type::Tiny::ALL_TYPES{ $constraint->{uniq} } = $constraint;
		
		if ( $constraint->can_be_inlined ) {
			push @code, sprintf(
				'(%s) or return Type::Tiny::_failed_check(%d, %s, %s, varname => %s, on_die => $on_die);',
				$really_optional
				? $constraint->type_parameter->inline_check( $varname )
				: $constraint->inline_check( $varname ),
				$constraint->{uniq},
				$QUOTE->( $constraint ),
				$varname,
				$is_slurpy
				? 'q{$SLURPY}'
				: sprintf( 'q{$_[%d]}', $arg + $options{arg_fudge_factor_head} ),
			);
		} #/ if ( $constraint->can_be_inlined)
		else {
			$env{'@check'}[$arg] =
				$really_optional
				? $constraint->type_parameter->compiled_check
				: $constraint->compiled_check;
			push @code, sprintf(
				'%s or return Type::Tiny::_failed_check(%d, %s, %s, varname => %s, on_die => $on_die);',
				sprintf( sprintf '$check[%d]->(%s)', $arg, $varname ),
				$constraint->{uniq},
				$QUOTE->( $constraint ),
				$varname,
				$is_slurpy
				? 'q{$SLURPY}'
				: sprintf( 'q{$_[%d]}', $arg + $options{arg_fudge_factor_head} ),
			);
		} #/ else [ if ( $constraint->can_be_inlined)]
		
		unless ( $return_list eq '@_' ) {
			push @code, sprintf 'push @R, %s;', $varname;
		}
	} #/ while ( @_ )
	
	my $thang = 'scalar(@_)';
	
	if ( $min_args == $max_args and not $saw_slurpy ) {
		$code[1] = sprintf(
			'return "Error::TypeTiny::WrongNumberOfParameters"->throw_cb($on_die, got => %s, minimum => %d, maximum => %d) if @_ != %d;',
			$thang,
			$min_args + $options{arg_fudge_factor},
			$max_args + $options{arg_fudge_factor},
			$min_args + $options{arg_fudge_factor},
		);
	}
	elsif ( $min_args < $max_args and not $saw_slurpy ) {
		$code[1] = sprintf(
			'return "Error::TypeTiny::WrongNumberOfParameters"->throw_cb($on_die, got => %s, minimum => %d, maximum => %d) if @_ < %d || @_ > %d;',
			$thang,
			$min_args + $options{arg_fudge_factor},
			$max_args + $options{arg_fudge_factor},
			$min_args + $options{arg_fudge_factor},
			$max_args + $options{arg_fudge_factor},
		);
	} #/ elsif ( $min_args < $max_args...)
	elsif ( $min_args and $saw_slurpy ) {
		$code[1] = sprintf(
			'return "Error::TypeTiny::WrongNumberOfParameters"->throw_cb($on_die, got => %s, minimum => %d) if @_ < %d;',
			$thang,
			$min_args + $options{arg_fudge_factor},
			$min_args + $options{arg_fudge_factor},
		);
	}
	
	push @code, $return_list;
	
	my $source = "sub { no warnings; " . join( "\n", @code ) . " };";

	return $source if $options{want_source};
	
	my $closure = eval_closure(
		source      => $source,
		description => $options{description}
			|| sprintf( "parameter validation for '%s'", $for ),
		environment => \%env,
	);
	
	return {
		min_args => $options{arg_fudge_factor} + ( $min_args || 0 ),
		max_args => $saw_slurpy
		? undef
		: $options{arg_fudge_factor} + ( $max_args || 0 ),
		closure     => $closure,
		source      => $source,
		environment => \%env,
	} if $options{want_details};
	
	return $closure;
} #/ sub compile

sub compile_named {
	my ( @code, %env );
	
	push @code, 'my (%R, %tmp, $tmp);';
	push @code, '#placeholder';           # $code[1]
	
	my %options;
	while ( ref( $_[0] ) eq "HASH" && !$_[0]{slurpy} ) {
		%options = ( %options, %{ +shift } );
	}
	my $arg = -1;
	my $had_slurpy;
	
	{
		my ( $extra_env, @extra_lines ) = _deal_with_on_die( \%options );
		if ( @extra_lines ) {
			$code[0] .= join '', @extra_lines;
			%env = ( %$extra_env, %env );
		}
	}
	
	{
		my ( $extra_env, @extra_lines ) = _deal_with_head_and_tail( \%options );
		if ( @extra_lines ) {
			push @code, @extra_lines;
			%env = ( %$extra_env, %env );
		}
	}
	
	my $for =
		$options{subname}
		|| [ caller( 1 + ( $options{caller_level} || 0 ) ) ]->[3]
		|| '__ANON__';
		
	push @code,
		'my %in = ((@_==1) && ref($_[0]) eq "HASH") ? %{$_[0]} : (@_ % 2) ? do { return "Error::TypeTiny::WrongNumberOfParameters"->throw_cb($on_die, message => "Odd number of elements in hash") } : @_;';
	my @names;
	
	while ( @_ ) {
		++$arg;
		my ( $name, $constraint ) = splice( @_, 0, 2 );
		push @names, $name;
		
		my $is_optional;
		my $really_optional;
		my $is_slurpy;
		my $varname;
		my $default;
		
		Types::Standard::is_Str( $name )
			or Error::TypeTiny::croak( "Expected parameter name as string, got $name" );
			
		my $param_options = {};
		$param_options = shift @_
			if Types::Standard::is_HashRef( $_[0] ) && !exists $_[0]{slurpy};
		$default = _mkdefault( $param_options );
		
		if ( $param_options->{optional} or defined $default ) {
			$is_optional = 1;
		}
		
		if ( Types::Standard::is_Bool( $constraint ) ) {
			$constraint =
				$constraint
				? Types::Standard::Any
				: Types::Standard::Optional [Types::Standard::Any];
		}
		
		if ( Types::Standard::is_HashRef( $constraint )
			and exists $constraint->{slurpy} )
		{
			$constraint = Types::TypeTiny::to_TypeTiny( $constraint->{slurpy} );
			++$is_slurpy;
			++$had_slurpy;
		}
		else {
			$is_optional += grep $_->{uniq} == Types::Standard::Optional->{uniq},
				$constraint->parents;
			$really_optional =
				$is_optional
				&& $constraint->parent
				&& $constraint->parent->{uniq} eq Types::Standard::Optional->{uniq}
				&& $constraint->type_parameter;
				
			$constraint = $constraint->type_parameter if $really_optional;
		} #/ else [ if ( Types::Standard::is_HashRef...)]
		
		if ( ref $default ) {
			$env{'@default'}[$arg] = $default;
			push @code, sprintf(
				'exists($in{%s}) or $in{%s} = $default[%d]->();',
				$QUOTE->( $name ),
				$QUOTE->( $name ),
				$arg,
			);
		}
		elsif ( defined $default ) {
			push @code, sprintf(
				'exists($in{%s}) or $in{%s} = %s;',
				$QUOTE->( $name ),
				$QUOTE->( $name ),
				$default,
			);
		}
		elsif ( not $is_optional || $is_slurpy ) {
			push @code, sprintf(
				'exists($in{%s}) or return "Error::TypeTiny::WrongNumberOfParameters"->throw_cb($on_die, message => sprintf "Missing required parameter: %%s", %s);',
				$QUOTE->( $name ),
				$QUOTE->( $name ),
			);
		}
		
		my $need_to_close_if = 0;
		
		if ( $is_slurpy ) {
			$varname = '\\%in';
		}
		elsif ( $is_optional ) {
			push @code, sprintf( 'if (exists($in{%s})) {',  $QUOTE->( $name ) );
			push @code, sprintf( '$tmp = delete($in{%s});', $QUOTE->( $name ) );
			$varname = '$tmp';
			++$need_to_close_if;
		}
		else {
			push @code, sprintf( '$tmp = delete($in{%s});', $QUOTE->( $name ) );
			$varname = '$tmp';
		}
		
		if ( $constraint->has_coercion ) {
			if ( $constraint->coercion->can_be_inlined ) {
				push @code, sprintf(
					'$tmp = %s;',
					$constraint->coercion->inline_coercion( $varname )
				);
			}
			else {
				$env{'@coerce'}[$arg] = $constraint->coercion->compiled_coercion;
				push @code, sprintf(
					'$tmp = $coerce[%d]->(%s);',
					$arg,
					$varname,
				);
			}
			$varname = '$tmp';
		} #/ if ( $constraint->has_coercion)
		
		if ( $constraint->can_be_inlined ) {
			push @code, sprintf(
				'(%s) or return Type::Tiny::_failed_check(%d, %s, %s, varname => %s, on_die => $on_die);',
				$constraint->inline_check( $varname ),
				$constraint->{uniq},
				$QUOTE->( $constraint ),
				$varname,
				$is_slurpy ? 'q{$SLURPY}' : sprintf( 'q{$_{%s}}', $QUOTE->( $name ) ),
			);
		} #/ if ( $constraint->can_be_inlined)
		else {
			$env{'@check'}[$arg] = $constraint->compiled_check;
			push @code, sprintf(
				'%s or return Type::Tiny::_failed_check(%d, %s, %s, varname => %s, on_die => $on_die);',
				sprintf( sprintf '$check[%d]->(%s)', $arg, $varname ),
				$constraint->{uniq},
				$QUOTE->( $constraint ),
				$varname,
				$is_slurpy ? 'q{$SLURPY}' : sprintf( 'q{$_{%s}}', $QUOTE->( $name ) ),
			);
		} #/ else [ if ( $constraint->can_be_inlined)]
		
		push @code, sprintf( '$R{%s} = %s;', $QUOTE->( $name ), $varname );
		
		push @code, '}' if $need_to_close_if;
	} #/ while ( @_ )
	
	if ( !$had_slurpy ) {
		push @code,
			'keys(%in) and return "Error::TypeTiny"->throw_cb($on_die, message => sprintf "Unrecognized parameter%s: %s", keys(%in)>1?"s":"", Type::Params::english_list(sort keys %in));';
	}
	
	if ( $options{named_to_list} ) {
		Error::TypeTiny::croak( "named_to_list option cannot be used with slurpy" )
			if $had_slurpy;
		my @order = ref $options{named_to_list} ? @{ $options{named_to_list} } : @names;
		push @code, sprintf( '@R{%s}', join ",", map $QUOTE->( $_ ), @order );
	}
	elsif ( $options{bless} ) {
		if ( $options{oo_trace} ) {
			push @code, sprintf( '$R{%s} = %s;', $QUOTE->( '~~caller' ), $QUOTE->( $for ) );
		}
		push @code, sprintf( 'bless \\%%R, %s;', $QUOTE->( $options{bless} ) );
	}
	elsif ( Types::Standard::is_ArrayRef( $options{class} ) ) {
		push @code,
			sprintf(
			'(%s)->%s(\\%%R);', $QUOTE->( $options{class}[0] ),
			$options{class}[1] || 'new'
			);
	}
	elsif ( $options{class} ) {
		push @code,
			sprintf(
			'(%s)->%s(\\%%R);', $QUOTE->( $options{class} ),
			$options{constructor} || 'new'
			);
	}
	else {
		push @code, '\\%R;';
	}
	
	if ( $options{head} || $options{tail} ) {
		$code[-1] = 'my @R = ' . $code[-1] . ';';
		push @code, 'unshift @R, @head;' if $options{head};
		push @code, 'push @R, @tail;'    if $options{tail};
		push @code, '@R;';
	}
	
	my $source = "sub { no warnings; " . join( "\n", @code ) . " };";
	return $source if $options{want_source};
	
	my $closure = eval_closure(
		source      => $source,
		description => $options{description}
			|| sprintf( "parameter validation for '%s'", $for ),
		environment => \%env,
	);
	
	my $max_args = undef;
	if ( !$had_slurpy ) {
		$max_args = 2 * ( $arg + 1 );
		$max_args += $options{arg_fudge_factor};
	}
	
	return {
		min_args    => $options{arg_fudge_factor},
		max_args    => $max_args,
		closure     => $closure,
		source      => $source,
		environment => \%env,
	} if $options{want_details};
	
	return $closure;
} #/ sub compile_named

my %klasses;
my $kls_id = 0;
my $has_cxsa;
my $want_cxsa;

sub _mkklass {
	my $klass = sprintf( '%s::OO::Klass%d', __PACKAGE__, ++$kls_id );
	
	if ( !defined $has_cxsa or !defined $want_cxsa ) {
		$has_cxsa = !!eval {
			require Class::XSAccessor;
			'Class::XSAccessor'->VERSION( '1.17' );    # exists_predicates, June 2013
			1;
		};
		
		$want_cxsa =
			$ENV{PERL_TYPE_PARAMS_XS}             ? 'XS'
			: exists( $ENV{PERL_TYPE_PARAMS_XS} ) ? 'PP'
			: $has_cxsa                           ? 'XS'
			:                                       'PP';
			
		if ( $want_cxsa eq 'XS' and not $has_cxsa ) {
			Error::TypeTiny::croak( "Cannot load Class::XSAccessor" );    # uncoverable statement
		}
	} #/ if ( !defined $has_cxsa...)
	
	if ( $want_cxsa eq 'XS' ) {
		eval {
			'Class::XSAccessor'->import(
				redefine => 1,
				class    => $klass,
				getters  => {
					map { defined( $_->{getter} ) ? ( $_->{getter} => $_->{slot} ) : () }
						values %{ $_[0] }
				},
				exists_predicates => {
					map { defined( $_->{predicate} ) ? ( $_->{predicate} => $_->{slot} ) : () }
						values %{ $_[0] }
				},
			);
			1;
		} ? return ( $klass ) : die( $@ );
	} #/ if ( $want_cxsa eq 'XS')
	
	for my $attr ( values %{ $_[0] } ) {
		defined( $attr->{getter} ) and eval sprintf(
			'package %s; sub %s { $_[0]{%s} }; 1',
			$klass,
			$attr->{getter},
			$attr->{slot},
		) || die( $@ );
		defined( $attr->{predicate} ) and eval sprintf(
			'package %s; sub %s { exists $_[0]{%s} }; 1',
			$klass,
			$attr->{predicate},
			$attr->{slot},
		) || die( $@ );
	} #/ for my $attr ( values %...)
	
	$klass;
} #/ sub _mkklass

sub compile_named_oo {
	my %options;
	while ( ref( $_[0] ) eq "HASH" && !$_[0]{slurpy} ) {
		%options = ( %options, %{ +shift } );
	}
	my @rest = @_;
	
	my %attribs;
	while ( @_ ) {
		my ( $name, $type ) = splice( @_, 0, 2 );
		my $opts =
			( Types::Standard::is_HashRef( $_[0] ) && !exists $_[0]{slurpy} )
			? shift( @_ )
			: {};
			
		my $is_optional = 0+ !!$opts->{optional};
		$is_optional += grep $_->{uniq} == Types::Standard::Optional->{uniq},
			$type->parents;
			
		my $getter =
			exists( $opts->{getter} )
			? $opts->{getter}
			: $name;
			
		Error::TypeTiny::croak( "Bad accessor name: $getter" )
			unless $getter =~ /\A[A-Za-z][A-Za-z0-9_]*\z/;
			
		my $predicate =
			exists( $opts->{predicate} )
			? (
			$opts->{predicate} eq '1'   ? "has_$getter"
			: $opts->{predicate} eq '0' ? undef
			:                             $opts->{predicate}
			)
			: ( $is_optional ? "has_$getter" : undef );
			
		$attribs{$name} = {
			slot      => $name,
			getter    => $getter,
			predicate => $predicate,
		};
	} #/ while ( @_ )
	
	my $kls = join '//',
		map sprintf(
		'%s*%s*%s', $attribs{$_}{slot}, $attribs{$_}{getter},
		$attribs{$_}{predicate} || '0'
		),
		sort keys %attribs;
		
	$klasses{$kls} ||= _mkklass( \%attribs );
	
	@_ = ( { oo_trace => 1, %options, bless => $klasses{$kls} }, @rest );
	goto \&compile_named;
} #/ sub compile_named_oo

# Would be faster to inline this into validate and validate_named, but
# that would complicate them. :/
sub _mk_key {
	local $_;
	join ':', map {
		Types::Standard::is_HashRef( $_ )
			? do {
			my %h = %$_;
			sprintf( '{%s}', _mk_key( map { ; $_ => $h{$_} } sort keys %h ) );
			}
			: Types::TypeTiny::is_TypeTiny( $_ ) ? sprintf( 'TYPE=%s', $_->{uniq} )
			: Types::Standard::is_Ref( $_ )      ? sprintf( 'REF=%s', refaddr( $_ ) )
			: Types::Standard::is_Undef( $_ )    ? sprintf( 'UNDEF' )
			: $QUOTE->( $_ )
	} @_;
} #/ sub _mk_key

my %compiled;

sub validate {
	my $arg = shift;
	my $sub = (
		$compiled{ _mk_key( @_ ) } ||= compile(
			{ caller_level => 1, %{ ref( $_[0] ) eq 'HASH' ? shift( @_ ) : +{} } },
			@_,
		)
	);
	@_ = @$arg;
	goto $sub;
} #/ sub validate

my %compiled_named;

sub validate_named {
	my $arg = shift;
	my $sub = (
		$compiled_named{ _mk_key( @_ ) } ||= compile_named(
			{ caller_level => 1, %{ ref( $_[0] ) eq 'HASH' ? shift( @_ ) : +{} } },
			@_,
		)
	);
	@_ = @$arg;
	goto $sub;
} #/ sub validate_named

sub multisig {
	my %options = ( ref( $_[0] ) eq "HASH" && !$_[0]{slurpy} ) ? %{ +shift } : ();
	$options{message}     ||= "Parameter validation failed";
	$options{description} ||= sprintf(
		"parameter validation for '%s'",
		[ caller( 1 + ( $options{caller_level} || 0 ) ) ]->[3] || '__ANON__'
	);
	for my $key ( qw[ message description ] ) {
		Types::TypeTiny::is_StringLike( $options{$key} )
			or Error::TypeTiny::croak(
			"Option '$key' expected to be string or stringifiable object" );
	}
	
	my @multi = map {
		Types::TypeTiny::is_CodeLike( $_ )       ? { closure => $_ }
			: Types::TypeTiny::is_ArrayLike( $_ ) ? compile( { want_details => 1 }, @$_ )
			:                                       $_;
	} @_;

	my %env;
	my @code = 'sub { my $r; ';
	
	{
		my ( $extra_env, @extra_lines ) = _deal_with_on_die( \%options );
		if ( @extra_lines ) {
			$code[0] .= join '', @extra_lines;
			%env = ( %$extra_env, %env );
		}
	}
	
	for my $i ( 0 .. $#multi ) {
		my $flag = sprintf( '${^TYPE_PARAMS_MULTISIG} = %d', $i );
		my $sig  = $multi[$i];
		my @cond;
		push @cond, sprintf( '@_ >= %s', $sig->{min_args} ) if defined $sig->{min_args};
		push @cond, sprintf( '@_ <= %s', $sig->{max_args} ) if defined $sig->{max_args};
		if ( defined $sig->{max_args} and defined $sig->{min_args} ) {
			@cond = sprintf( '@_ == %s', $sig->{min_args} )
				if $sig->{max_args} == $sig->{min_args};
		}
		push @code, sprintf( 'if (%s){', join( ' and ', @cond ) ) if @cond;
		push @code,
			sprintf(
			'eval { $r = [ $multi[%d]{closure}->(@_) ]; %s };', $i,
			$flag
			);
		push @code, 'return(@$r) if $r;';
		push @code, '}' if @cond;
	} #/ for my $i ( 0 .. $#multi)
	
	push @code,
		sprintf(
		'return "Error::TypeTiny"->throw_cb($on_die, message => "%s");',
		quotemeta( "$options{message}" )
		);
	push @code, '}';
	
	eval_closure(
		source      => \@code,
		description => $options{description},
		environment => { '@multi' => \@multi, %env },
	);
} #/ sub multisig

sub wrap_methods {
	my $opts = ref( $_[0] ) eq 'HASH' ? shift : {};
	$opts->{caller} ||= caller;
	$opts->{skip_invocant} = 1;
	$opts->{use_can}       = 1;
	unshift @_, $opts;
	goto \&_wrap_subs;
}

sub wrap_subs {
	my $opts = ref( $_[0] ) eq 'HASH' ? shift : {};
	$opts->{caller} ||= caller;
	$opts->{skip_invocant} = 0;
	$opts->{use_can}       = 0;
	unshift @_, $opts;
	goto \&_wrap_subs;
}

sub _wrap_subs {
	my $opts = shift;
	my $subname =
		eval   { require Sub::Util } ? \&Sub::Util::set_subname
		: eval { require Sub::Name } ? \&Sub::Name::subname
		:                              0;
	while ( @_ ) {
		my ( $name, $proto ) = splice @_, 0, 2;
		my $fullname =
			( $name =~ /::/ )
			? $name
			: sprintf( '%s::%s', $opts->{caller}, $name );
		my $orig = do {
			no strict 'refs';
			exists &$fullname     ? \&$fullname
				: $opts->{use_can} ? ( $opts->{caller}->can( $name ) || sub { } )
				: sub { }
		};
		my $check = ref( $proto ) eq 'CODE' ? $proto : undef;
		my $co    = { description => "parameter validation for '$name'" };
		my $new   = $opts->{skip_invocant}
			? sub {
			my $s = shift;
			$check ||= compile( $co, @$proto );
			@_ = ( $s, &$check );
			goto $orig;
			}
			: sub {
			$check ||= compile( $co, @$proto );
			@_ = ( &$check );
			goto $orig;
			};
		$new = $subname->( $fullname, $new ) if $subname;
		no strict 'refs';
		no warnings 'redefine';
		*$fullname = $new;
	} #/ while ( @_ )
	1;
} #/ sub _wrap_subs

1;

__END__

=pod

=encoding utf-8

=for stopwords evals invocant

=head1 NAME

Type::Params - Params::Validate-like parameter validation using Type::Tiny type constraints and coercions

=head1 SYNOPSIS

 use v5.12;
 use strict;
 use warnings;
 
 package Horse {
   use Moo;
   use Types::Standard qw( Object );
   use Type::Params qw( compile );
   use namespace::autoclean;
   
   ...;   # define attributes, etc
   
   sub add_child {
     state $check = compile( Object, Object );  # method signature
     
     my ($self, $child) = $check->(@_);         # unpack @_
     push @{ $self->children }, $child;
     
     return $self;
   }
 }
 
 package main;
 
 my $boldruler = Horse->new;
 
 $boldruler->add_child( Horse->new );
 
 $boldruler->add_child( 123 );   # dies (123 is not an Object!)

=head1 STATUS

This module is covered by the
L<Type-Tiny stability policy|Type::Tiny::Manual::Policies/"STABILITY">.

=head1 DESCRIPTION

This documents the details of the L<Type::Params> package.
L<Type::Tiny::Manual> is a better starting place if you're new.

Type::Params uses L<Type::Tiny> constraints to validate the parameters to a
sub. It takes the slightly unorthodox approach of separating validation
into two stages:

=over

=item 1.

Compiling the parameter specification into a coderef; then

=item 2.

Using the coderef to validate parameters.

=back

The first stage is slow (it might take a couple of milliseconds), but you
only need to do it the first time the sub is called. The second stage is
fast; according to my benchmarks faster even than the XS version of
L<Params::Validate>.

If you're using a modern version of Perl, you can use the C<state> keyword
which was a feature added to Perl in 5.10. If you're stuck on Perl 5.8, the
example from the SYNOPSIS could be rewritten as:

   my $add_child_check;
   sub add_child {
     $add_child_check ||= compile( Object, Object );
     
     my ($self, $child) = $add_child_check->(@_);  # unpack @_
     push @{ $self->children }, $child;
     
     return $self;
   }

Not quite as neat, but not awful either.

If you don't like the two step, there's a shortcut reducing it to one step:

   use Type::Params qw( validate );
   
   sub add_child {
     my ($self, $child) = validate(\@_, Object, Object);
     push @{ $self->children }, $child;
     return $self;
   }

Type::Params has a few tricks up its sleeve to make sure performance doesn't
suffer too much with the shortcut, but it's never going to be as fast as the
two stage compile/execute.

=head2 Functions

=head3 C<< compile(@spec) >>

Given specifications for positional parameters, compiles a coderef
that can check against them.

The generalized form of specifications for positional parameters is:

 state $check = compile(
   \%general_opts,
   $type_for_arg_1, \%opts_for_arg_1,
   $type_for_arg_2, \%opts_for_arg_2,
   $type_for_arg_3, \%opts_for_arg_3,
   ...,
   slurpy($slurpy_type),
 );

If a hashref of options is empty, it can simply be omitted. Much of the
time, you won't need to specify any options.

 # In this example, we omit all the hashrefs
 #
 my $check = compile(
   Str,
   Int,
   Optional[ArrayRef],
 );
 
 my ($str, $int, $arr) = $check->("Hello", 42, []);   # ok
 my ($str, $int, $arr) = $check->("", -1);            # ok
 my ($str, $int, $arr) = $check->("", -1, "bleh");    # dies

The coderef returned (i.e. C<< $check >>) will check the arguments
passed to it conform to the spec (coercing them if appropriate),
and return them as a list if they do. If they don't, it will throw
an exception.

The first hashref, before any type constraints, is for general options
which affect the entire compiled coderef. Currently supported general
options are:

=over

=item C<< head >> B<< Int|ArrayRef[TypeTiny] >>

Parameters to shift off C<< @_ >> before doing the main type check.
These parameters may also be checked, and cannot be optional or slurpy.
They may not have defaults.

  my $check = compile(
    { head => [ Int, Int ] },
    Str,
    Str,
  );
  
  # ... is basically the same as...
  
  my $check = compile(
    Int,
    Int,
    Str,
    Str,
  );

A number may be given if you do not care to check types:

  my $check = compile(
    { head => 2 },
    Str,
    Str,
  );
  
  # ... is basically the same as...
  
  my $check = compile(
    Any,
    Any,
    Str,
    Str,
  );

This is mostly useless for C<compile>, but can be useful for
C<compile_named> and C<compile_named_oo>.

=item C<< tail >> B<< Int|ArrayRef[TypeTiny] >>

Similar to C<head>, but pops parameters off the end of C<< @_ >> instead.
This is actually useful for C<compile> because it allows you to sneak in
some required parameters I<after> a slurpy or optional parameter.

  my $check = compile(
    { tail => [ CodeRef ] },
    slurpy ArrayRef[Str],
  );
  
  my ($strings, $coderef) = $check->("foo", "bar", sub { ... });

=item C<< want_source >> B<< Bool >>

Instead of returning a coderef, return Perl source code string. Handy
for debugging.

=item C<< want_details >> B<< Bool >>

Instead of returning a coderef, return a hashref of stuff including the
coderef. This is mostly for people extending Type::Params and I won't go
into too many details about what else this hashref contains.

=item C<< description >> B<< Str >>

Description of the coderef that will show up in stack traces. Defaults to
"parameter validation for X" where X is the caller sub name.

=item C<< subname >> B<< Str >>

If you wish to use the default description, but need to change the sub name,
use this.

=item C<< caller_level >> B<< Int >>

If you wish to use the default description, but need to change the caller
level for detecting the sub name, use this.

=item C<< on_die >> B<< Maybe[CodeRef] >>

  my $check = compile(
    { on_die => sub { ... } },
    ...,
  );
  
  my @args = $check->( @_ );

Normally, at the first invalid argument the C<< $check >> coderef encounters,
it will throw an exception.

If an C<on_die> coderef is provided, then it is called instead, and the
exception is passed to it as an object. The C<< $check >> coderef will still
immediately return though.

=back

The types for each parameter may be any L<Type::Tiny> type constraint, or
anything that Type::Tiny knows how to coerce into a Type::Tiny type
constraint, such as a MooseX::Types type constraint or a coderef.

Type coercions are automatically applied for all types that have
coercions.

If you wish to avoid coercions for a type, use Type::Tiny's
C<no_coercions> method.

 my $check = compile(
   Int,
   ArrayRef->of(Bool)->no_coercions,
 );

Note that having any coercions in a specification, even if they're not
used in a particular check, will slightly slow down C<< $check >>
because it means that C<< $check >> can't just check C<< @_ >> and return
it unaltered if it's valid — it needs to build a new array to return.

Optional parameters can be given using the B<< Optional[] >> type
constraint. In the example above, the third parameter is optional.
If it's present, it's required to be an arrayref, but if it's absent,
it is ignored.

Optional parameters need to be I<after> required parameters in the
spec.

An alternative way to specify optional parameters is using a parameter
options hashref.

 my $check = compile(
   Str,
   Int,
   ArrayRef, { optional => 1 },
 );

The following parameter options are supported:

=over

=item C<< optional >> B<< Bool >>

This is an alternative way of indicating that a parameter is optional.

 state $check = compile(
   Int,
   Int, { optional => 1 },
   Optional[Int],
 );

The two are not I<exactly> equivalent. The exceptions thrown will
differ in the type name they mention. (B<Int> versus B<< Optional[Int] >>.)

=item C<< default >> B<< CodeRef|Ref|Str|Undef >>

A default may be provided for a parameter.

 state $check = compile(
   Int,
   Int, { default => "666" },
   Int, { default => "999" },
 );

Supported defaults are any strings (including numerical ones), C<undef>,
and empty hashrefs and arrayrefs. Non-empty hashrefs and arrayrefs are
I<< not allowed as defaults >>.

Alternatively, you may provide a coderef to generate a default value:

 state $check = compile(
   Int,
   Int, { default => sub { 6 * 111 } },
   Int, { default => sub { 9 * 111 } },
 );

That coderef may generate any value, including non-empty arrayrefs and
non-empty hashrefs. For undef, simple strings, numbers, and empty
structures, avoiding using a coderef will make your parameter processing
faster.

The default I<will> be validated against the type constraint, and
potentially coerced.

Note that having any defaults in a specification, even if they're not
used in a particular check, will slightly slow down C<< $check >>
because it means that C<< $check >> can't just check C<< @_ >> and return
it unaltered if it's valid — it needs to build a new array to return.

=back

As a special case, the numbers 0 and 1 may be used as shortcuts for
B<< Optional[Any] >> and B<< Any >>.

 # Positional parameters
 state $check = compile(1, 0, 0);
 my ($foo, $bar, $baz) = $check->(@_);  # $bar and $baz are optional

After any required and optional parameters may be a slurpy parameter.
Any additional arguments passed to C<< $check >> will be slurped into
an arrayref or hashref and checked against the slurpy parameter.
Defaults are not supported for slurpy parameters.

Example with a slurpy ArrayRef:

 sub xyz {
   state $check = compile(Int, Int, slurpy ArrayRef[Int]);
   my ($foo, $bar, $baz) = $check->(@_);
 }
 
 xyz(1..5);  # $foo = 1
             # $bar = 2
             # $baz = [ 3, 4, 5 ]

Example with a slurpy HashRef:

 my $check = compile(
   Int,
   Optional[Str],
   slurpy HashRef[Int],
 );
 
 my ($x, $y, $z) = $check->(1, "y", foo => 666, bar => 999);
 # $x is 1
 # $y is "y"
 # $z is { foo => 666, bar => 999 }

Any type constraints derived from B<ArrayRef> or B<HashRef> should work,
but a type does need to inherit from one of those because otherwise
Type::Params cannot know what kind of structure to slurp the remaining
arguments into.

B<< slurpy Any >> is also allowed as a special case, and is treated as
B<< slurpy ArrayRef >>.

From Type::Params 1.005000 onwards, slurpy hashrefs can be passed in as a
true hashref (which will be shallow cloned) rather than key-value pairs.

 sub xyz {
   state $check = compile(Int, slurpy HashRef);
   my ($num, $hr) = $check->(@_);
   ...
 }
 
 xyz( 5,   foo => 1, bar => 2   );   # works
 xyz( 5, { foo => 1, bar => 2 } );   # works from 1.005000

This feature is only implemented for slurpy hashrefs, not slurpy arrayrefs.

Note that having a slurpy parameter will slightly slow down C<< $check >>
because it means that C<< $check >> can't just check C<< @_ >> and return
it unaltered if it's valid — it needs to build a new array to return.

=head3 C<< validate(\@_, @spec) >>

This example of C<compile>:

 sub foo {
   state $check = compile(@spec);
   my @args = $check->(@_);
   ...;
 }

Can be written using C<validate> as:

 sub foo {
   my @args = validate(\@_, @spec);
   ...;
 }

Performance using C<compile> will I<always> beat C<validate> though.

=head3 C<< compile_named(@spec) >>

C<compile_named> is a variant of C<compile> for named parameters instead
of positional parameters.

The format of the specification is changed to include names for each
parameter:

 state $check = compile_named(
   \%general_opts,
   foo   => $type_for_foo, \%opts_for_foo,
   bar   => $type_for_bar, \%opts_for_bar,
   baz   => $type_for_baz, \%opts_for_baz,
   ...,
   extra => slurpy($slurpy_type),
 );

The C<< $check >> coderef will return a hashref.

 my $check = compile_named(
   foo => Int,
   bar => Str, { default => "hello" },
 );
 
 my $args = $check->(foo => 42);
 # $args->{foo} is 42
 # $args->{bar} is "hello"

The C<< %general_opts >> hash supports the same options as C<compile>
plus a few additional options:

=over

=item C<< class >> B<< ClassName >>

The check coderef will, instead of returning a simple hashref, call
C<< $class->new($hashref) >> and return the result.

=item C<< constructor >> B<< Str >>

Specifies an alternative method name instead of C<new> for the C<class>
option described above.

=item C<< class >> B<< Tuple[ClassName, Str] >>

Shortcut for declaring both the C<class> and C<constructor> options at once.

=item C<< bless >> B<< ClassName >>

Like C<class>, but bypass the constructor and directly bless the hashref.

=item C<< named_to_list >> B<< Bool >>

Instead of returning a hashref, return a hash slice.

 myfunc(bar => "x", foo => "y");
 
 sub myfunc {
    state $check = compile_named(
       { named_to_list => 1 },
       foo => Str, { optional => 1 },
       bar => Str, { optional => 1 },
    );
    my ($foo, $bar) = $check->(@_);
    ...; ## $foo is "y" and $bar is "x"
 }

The order of keys for the hash slice is the same as the order of the names
passed to C<compile_named>. For missing named parameters, C<undef> is
returned in the list.

Basically in the above example, C<myfunc> takes named parameters, but
receieves positional parameters.

=item C<< named_to_list >> B<< ArrayRef[Str] >>

As above, but explicitly specify the keys of the hash slice.

=back

Like C<compile>, the numbers 0 and 1 may be used as shortcuts for
B<< Optional[Any] >> and B<< Any >>.

 state $check = compile_named(foo => 1, bar => 0, baz => 0);
 my $args = $check->(@_);  # $args->{bar} and $args->{baz} are optional

Slurpy parameters are slurped into a nested hashref.

  my $check = compile(
    foo    => Str,
    bar    => Optional[Str],
    extra  => slurpy HashRef[Str],
  );
  my $args = $check->(foo => "aaa", quux => "bbb");
  
  print $args->{foo}, "\n";             # aaa
  print $args->{extra}{quux}, "\n";     # bbb

B<< slurpy Any >> is treated as B<< slurpy HashRef >>.

The C<head> and C<tail> options are supported. This allows for a
mixture of positional and named arguments, as long as the positional
arguments are non-optional and at the head and tail of C<< @_ >>.

  my $check = compile(
    { head => [ Int, Int ], tail => [ CodeRef ] },
    foo => Str,
    bar => Str,
    baz => Str,
  );
  
  my ($int1, $int2, $args, $coderef)
    = $check->( 666, 999, foo=>'x', bar=>'y', baz=>'z', sub {...} );
  
  say $args->{bar};  # 'y'

This can be combined with C<named_to_list>:

  my $check = compile(
    { head => [ Int, Int ], tail => [ CodeRef ], named_to_list => 1 },
    foo => Str,
    bar => Str,
    baz => Str,
  );
  
  my ($int1, $int2, $foo, $bar, $baz, $coderef)
    = $check->( 666, 999, foo=>'x', bar=>'y', baz=>'z', sub {...} );
  
  say $bar;  # 'y'

=head3 C<< validate_named(\@_, @spec) >>

Like C<compile> has C<validate>, C<compile_named> has C<validate_named>.
Just like C<validate>, it's the slower way to do things, so stick with
C<compile_named>.

=head3 C<< compile_named_oo(@spec) >>

Here's a quick example function:

   sub add_contact_to_database {
      state $check = compile_named(
         dbh     => Object,
         id      => Int,
         name    => Str,
      );
      my $arg = $check->(@_);
      
      my $sth = $arg->{db}->prepare('INSERT INTO contacts VALUES (?, ?)');
      $sth->execute($arg->{id}, $arg->{name});
   }

Looks simple, right? Did you spot that it will always die with an error
message I<< Can't call method "prepare" on an undefined value >>?

This is because we defined a parameter called 'dbh' but later tried to
refer to it as C<< $arg{db} >>. Here, Perl gives us a pretty clear
error, but sometimes the failures will be far more subtle. Wouldn't it
be nice if instead we could do this?

   sub add_contact_to_database {
      state $check = compile_named_oo(
         dbh     => Object,
         id      => Int,
         name    => Str,
      );
      my $arg = $check->(@_);
      
      my $sth = $arg->dbh->prepare('INSERT INTO contacts VALUES (?, ?)');
      $sth->execute($arg->id, $arg->name);
   }

If we tried to call C<< $arg->db >>, it would fail because there was
no such method.

Well, that's exactly what C<compile_named_oo> does.

As well as giving you nice protection against mistyped parameter names,
It also looks kinda pretty, I think. Hash lookups are a little faster
than method calls, of course (though Type::Params creates the methods
using L<Class::XSAccessor> if it's installed, so they're still pretty
fast).

An optional parameter C<foo> will also get a nifty C<< $arg->has_foo >>
predicate method. Yay!

C<compile_named_oo> gives you some extra options for parameters.

   sub add_contact_to_database {
      state $check = compile_named_oo(
         dbh     => Object,
         id      => Int,    { default => '0', getter => 'identifier' },
         name    => Str,    { optional => 1, predicate => 'has_name' },
      );
      my $arg = $check->(@_);
      
      my $sth = $arg->dbh->prepare('INSERT INTO contacts VALUES (?, ?)');
      $sth->execute($arg->identifier, $arg->name) if $arg->has_name;
   }

=over

=item C<< getter >> B<< Str >>

The C<getter> option lets you choose the method name for getting the
argument value.

=item C<< predicate >> B<< Str >>

The C<predicate> option lets you choose the method name for checking
the existence of an argument. By setting an explicit predicate method
name, you can force a predicate method to be generated for non-optional
arguments.

=back

The objects returned by C<compile_named_oo> are blessed into lightweight
classes which have been generated on the fly. Don't expect the names of
the classes to be stable or predictable. It's probably a bad idea to be
checking C<can>, C<isa>, or C<DOES> on any of these objects. If you're
doing that, you've missed the point of them.

They don't have any constructor (C<new> method). The C<< $check >>
coderef effectively I<is> the constructor.

=head3 C<< validate_named_oo(\@_, @spec) >>

This function doesn't even exist. :D

=head3 C<< multisig(@alternatives) >>

Type::Params can export a C<multisig> function that compiles multiple
alternative signatures into one, and uses the first one that works:

   state $check = multisig(
      [ Int, ArrayRef ],
      [ HashRef, Num ],
      [ CodeRef ],
   );
   
   my ($int, $arrayref) = $check->( 1, [] );      # okay
   my ($hashref, $num)  = $check->( {}, 1.1 );    # okay
   my ($code)           = $check->( sub { 1 } );  # okay
   
   $check->( sub { 1 }, 1.1 );  # throws an exception

Coercions, slurpy parameters, etc still work.

The magic global C<< ${^TYPE_PARAMS_MULTISIG} >> is set to the index of
the first signature which succeeded.

The present implementation involves compiling each signature independently,
and trying them each (in their given order!) in an C<eval> block. The only
slightly intelligent part is that it checks if C<< scalar(@_) >> fits into
the signature properly (taking into account optional and slurpy parameters),
and skips evals which couldn't possibly succeed.

It's also possible to list coderefs as alternatives in C<multisig>:

   state $check = multisig(
      [ Int, ArrayRef ],
      sub { ... },
      [ HashRef, Num ],
      [ CodeRef ],
      compile_named( needle => Value, haystack => Ref ),
   );

The coderef is expected to die if that alternative should be abandoned (and
the next alternative tried), or return the list of accepted parameters. Here's
a full example:

   sub get_from {
      state $check = multisig(
         [ Int, ArrayRef ],
         [ Str, HashRef ],
         sub {
            my ($meth, $obj) = @_;
            die unless is_Object($obj);
            die unless $obj->can($meth);
            return ($meth, $obj);
         },
      );
      
      my ($needle, $haystack) = $check->(@_);
      
      for (${^TYPE_PARAMS_MULTISIG}) {
         return $haystack->[$needle] if $_ == 0;
         return $haystack->{$needle} if $_ == 1;
         return $haystack->$needle   if $_ == 2;
      }
   }
   
   get_from(0, \@array);      # returns $array[0]
   get_from('foo', \%hash);   # returns $hash{foo}
   get_from('foo', $obj);     # returns $obj->foo
   
The default error message is just C<"Parameter validation failed">.
You can pass an option hashref as the first argument with an informative
message string:

   sub foo {
      state $OptionsDict = Dict[...];
      state $check = multisig(
         { message => 'USAGE: $object->foo(\%options?, $string)' },
         [ Object, $OptionsDict, StringLike ],
         [ Object, StringLike ],
      );
      my ($self, @args) = $check->(@_);
      my ($opts, $str)  = ${^TYPE_PARAMS_MULTISIG} ? ({}, @args) : @_;
      ...;
   }
   
   $obj->foo(\%opts, "Hello");
   $obj->foo("World");

=head3 C<< wrap_subs( $subname1, $wrapper1, ... ) >>

It's possible to turn the check inside-out and instead of the sub calling
the check, the check can call the original sub.

Normal way:

   use Type::Param qw(compile);
   use Types::Standard qw(Int Str);
   
   sub foobar {
      state $check = compile(Int, Str);
      my ($foo, $bar) = @_;
      ...;
   }

Inside-out way:

   use Type::Param qw(wrap_subs);
   use Types::Standard qw(Int Str);
   
   sub foobar {
      my ($foo, $bar) = @_;
      ...;
   }
   
   wrap_subs foobar => [Int, Str];

C<wrap_subs> takes a hash of subs to wrap. The keys are the sub names and the
values are either arrayrefs of arguments to pass to C<compile> to make a check,
or coderefs that have already been built by C<compile>, C<compile_named>, or
C<compile_named_oo>.

=head3 C<< wrap_methods( $subname1, $wrapper1, ... ) >>

C<wrap_methods> also exists, which shifts off the invocant from C<< @_ >>
before the check, but unshifts it before calling the original sub.

   use Type::Param qw(wrap_methods);
   use Types::Standard qw(Int Str);
   
   sub foobar {
      my ($self, $foo, $bar) = @_;
      ...;
   }
   
   wrap_methods foobar => [Int, Str];

=head3 B<Invocant>

Type::Params exports a type B<Invocant> on request. This gives you a type
constraint which accepts classnames I<and> blessed objects.

 use Type::Params qw( compile Invocant );
 
 sub my_method {
   state $check = compile(Invocant, ArrayRef, Int);
   my ($self_or_class, $arr, $ix) = $check->(@_);
   
   return $arr->[ $ix ];
 }

=head3 B<ArgsObject>

Type::Params exports a parameterizable type constraint B<ArgsObject>.
It accepts the kinds of objects returned by C<compile_named_oo> checks.

  package Foo {
    use Moo;
    use Type::Params 'ArgsObject';
    
    has args => (
      is  => 'ro',
      isa => ArgsObject['Bar::bar'],
    );
  }
  
  package Bar {
    use Types::Standard -types;
    use Type::Params 'compile_named_oo';
    
    sub bar {
      state $check = compile_named_oo(
        xxx => Int,
        yyy => ArrayRef,
      );
      my $args = &$check;
      
      return 'Foo'->new( args => $args );
    }
  }
  
  Bar::bar( xxx => 42, yyy => [] );

The parameter "Bar::bar" refers to the caller when the check is compiled,
rather than when the parameters are checked.

=head1 ENVIRONMENT

=over

=item C<PERL_TYPE_PARAMS_XS>

Affects the building of accessors for C<compile_named_oo>. If set to true,
will use L<Class::XSAccessor>. If set to false, will use pure Perl. If this
environment variable does not exist, will use L<Class::XSAccessor> if it
is available.

=back

=head1 BUGS

Please report any bugs to
L<https://github.com/tobyink/p5-type-tiny/issues>.

=head1 SEE ALSO

L<The Type::Tiny homepage|https://typetiny.toby.ink/>.

L<Type::Tiny>, L<Type::Coercion>, L<Types::Standard>.

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

=head1 COPYRIGHT AND LICENCE

This software is copyright (c) 2013-2014, 2017-2022 by Toby Inkster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=head1 DISCLAIMER OF WARRANTIES

THIS PACKAGE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.
