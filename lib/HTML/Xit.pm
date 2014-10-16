package HTML::Xit;

use strict;
use warnings;

use Data::Dumper;
use HTML::Selector::XPath qw(
    selector_to_xpath
);
use Scalar::Util qw(
    blessed
    reftype
);
use XML::LibXML;



# default arguments for XML::LibXML
my $default_libxml_args = {
    recover  => 1,
    suppress_errors => 1,
    suppress_warnings => 1,
};

###################
#                 #
# PRIVATE METHODS #
#                 #
###################

# new_explicit_args
#
# create new XML::LibXML instance with args that are passed
my $new_explicit_args = sub {
    my %args = @_;

    for my $arg (keys %$default_libxml_args) {
        # set default args values unless the arg is
        # explicitly set
        $args{$arg} = $default_libxml_args->{$arg}
            unless exists $args{$arg};
    }

    return {
        _xml => XML::LibXML->load_html( %args )
    };
};

# new_guess_args
#
# guess source as one of IO, location, or string based
# on the type of scalar that is passed.
#
# call new_explicit_args once type is guessed.
my $new_guess_args = sub {
    my $arg = shift or die;

    if (ref $arg) {
        # file handle
        if (reftype $arg eq 'GLOB') {
            return $new_explicit_args->(IO => $arg);
        }
        # scalar ref
        elsif (reftype $arg eq 'SCALAR') {
            return $new_explicit_args->(string => $arg);
        }
    }
    # url or valid file path
    elsif ($arg =~ m{^http} || -e $arg) {
        return $new_explicit_args->(location => $arg);
    }
    # text
    else {
        return $new_explicit_args->(string => $arg);
    }
};

# declare this first since we need to call in from closure
my $new_X;
# new_X
#
# create a new X instance which is a function reference that
# can return a hidden hash ref instance where data is stored
$new_X = sub {
    my($self) = @_;
    # self must be a hash ref that includes a XML::LibXML object
    return unless eval { $self->{_xml} };

    my $X;
    # HTML::Xit instance
    $X = sub {
        my($select) = @_;
        # if we are passed a self-reference then
        # return our hidden instance variable
        return $self
            if ref $select
            and $select eq $X;

        my $xml = $self->{_xml};
        # else create a new instance
        my $self = {};
        # create new node
        if ($select =~ m{^<([^>]+)>$}) {
            my $node_name = $1;
            # try to get XML::LibXML::Document
            my $doc = $xml
                # if the current node supports createElement then use it
                ? $xml->can('createElement')
                    ? $xml
                    # if the current belongs to a Document then use that
                    : $xml->can('ownerDocument')
                        ? $xml->ownerDocument
                        : XML::LibXML::Document->new
                # create a new Document to create node from
                : XML::LibXML::Document->new;
            # create element under document
            $xml = $self->{_xml} = $doc->createElement($node_name);
        }
        # value is selector
        else {
            # generate xpath from CSS selector using HTML::Selector::XPath
            my $xpath = selector_to_xpath($select)
                or return $X;
            # set the current xml context as the result of the xpath selection
            $self->{_xml} = $xml->find('.'.$xpath);
        }
        # return a new HTML::Xit instace with either the selected or created elements
        return $new_X->($self);
    };

    return bless($X, __PACKAGE__);
};

# each
#
# call callback function for each argument
#
# unlike the public version of this method the private version does
# not create HTML::Xit instances around the returned object.
my $each = sub {
    my($elm, $func) = @_;

    if (ref $elm && reftype $elm eq 'ARRAY') {
        $func->($_) for @$elm;
    }
    else {
        $func->($elm);
    }
};

# first
#
# return the first element from array or return arg if not an array.
#
# unlike the public version of this method the private version does
# not create HTML::Xit instances around the returned object.
my $first = sub {
    my($elm) = @_;

    return ref $elm && reftype $elm eq 'ARRAY'
        ? $elm->[0]
        : $elm;
};

# arg_to_nodes
#
# take one or more arguments that may be strings of xml/html
# Xit objects referencing XML, or XML objects and return an
# XML fragment
my $arg_to_nodes = sub
{
    my $parser = XML::LibXML->new(%$default_libxml_args)
        or return;

    my $nodes = [];

    for my $arg (@_) {
        if (ref $arg) {
            if ($arg->isa('HTML::Xit')) {
                push(@$nodes, @{$arg->get});
            }
        }
        else {
            my $xml = $parser->parse_balanced_chunk($arg);
            push(@$nodes, $xml);
        }
    }

    return $nodes;
};

# mod_class
#
# perform addClass, removeClass, and toggleClass methods
my $mod_class = sub {
    my($action, $X, $value) = @_;

    return $X unless $value;

    my $self = $X->($X);
    my $xml  = $self->{_xml} or return $X;
    # class list may be one or more space seperated class names
    my @mod_classes = grep {$_ =~ /\w+/} split(/\s+/, $value);

    return $X unless @mod_classes;

    $each->($xml, sub {
        my($sel) = @_;

        my $class = $sel->getAttribute('class');

        my $classes = {
            map {$_ => 1} grep {$_ =~ /\w+/} split(/\s+/, $class)
        };

        if ($action eq 'add') {
            $classes->{$_} = 1 for @mod_classes;
        }
        elsif ($action eq 'remove') {
            delete $classes->{$_} for @mod_classes;
        }
        elsif ($action eq 'toggle') {
            for my $mod_class (@mod_classes) {
                if ($classes->{$mod_class}) {
                    delete $classes->{$mod_class};
                }
                else {
                    $classes->{$mod_class} = 1;
                }
            }
        }

        $class = join(' ', sort keys %$classes);

        $sel->setAttribute('class', $class);
    });

    return $X;
};

##################
#                #
# PUBLIC METHODS #
#                #
##################

# new
#
# create new HTML::Xit instance which is a function ref
sub new
{
    my $class = shift;
    # process args which may be in the form of:
    # new("<html>...")
    # new("http://www...")
    # new(FH)
    # new("/my/file.html")
    # new(a => 1, b => 2, ...)
    # new({a => 1, b => 2})
    my $self = @_ == 1
        ? ref $_[0] && ref $_[0] eq 'HASH'
            # first arg is hash ref, use as args
            ? $new_explicit_args->( %{$_[0]} )
            # first arg is not hash ref, guess what it is
            : $new_guess_args->(@_)
        # treat multiple args as explicit, which are passed
        # directly to XML::LibXML
        : $new_explicit_args->(@_);
    # need XML::LibXML instance to continue
    return unless $self and $self->{_xml};

    return $new_X->($self);
}

# attr
#
# get or set an attribute on selected XML nodes
sub attr
{
    my($X, $name, $value) = @_;
    my $self = $X->($X);
    my $xml  = $self->{_xml} or return $X;

    if (defined $value)
    {
        $each->($xml, sub {
            my $sel = shift or return;

            $sel->setAttribute($name, $value)
                if $sel->can('setAttribute');
        });
    }
    else
    {
        my $sel = $first->($xml);

        return $sel->getAttribute($name)
            if $sel->can('getAttribute');
        return;
    }

    return $X;
}

# each
#
# call callback function for each argument
#
# unlike the private version, this method creates a new
# HTML::Xit instance for each XML element being iterated on
sub each
{
    my($X, $func) = @_;
    my $self = $X->($X);

    my $xml = $self->{_xml} or return $X;

    if (ref $xml && reftype $xml eq 'ARRAY') {
        # call callback for each element in array, creating a
        # new HTML::Xit instance for each XML element
        $func->( $new_X->({_xml => $node}) ) for @$xml;
    }
    else {
        # call callback, creating a new HTML::Xit instance
        $func->( $new_X->({_xml => $node}) );
    }

    return $X;
}

# first
#
# return the first element from array or return arg if not an array.
#
# unlike the private version, this method creates a new
# HTML::Xit instance for node being returned
sub first {
    my($X) = @_;
    my $self = $X->($X);

    my $xml = $self->{_xml} or return $X;

    return ref $xml && reftype $xml eq 'ARRAY'
        ? $new_X->( {_xml => $xml->[0]} )
        : $new_X->( {_xml => $xml} );
};

# get
#
# return the XML::LibXML nodes or node identified by index
sub get
{
    my($X, $index) = @_;
    my $self = $X->($X);

    my $xml = $self->{_xml} or return $X;
    # make sure we have nodes in array
    my $nodes = ref $xml && reftype $xml eq 'ARRAY'
        ? $xml : [ $xml ];
    # return either all nodes or specified index
    return defined $index && int $index
        ? $nodes->[ $index ]
        : $nodex;
}

# html
#
# return html content or if that is not possible return text
# content
sub html
{
    my($X) = shift;
    my $self = $X->($X);

    my $xml = $self->{_xml} or return $X;

    if (@_) {
        my $child_nodes = $arg_to_nodes->(@_)
            or return $X;

        $each->($xml, sub {
            my $sel = shift or return;
            # must be able to have children
            return unless $sel->can('appendChild');
            # html replaces any existing child nodes
            $sel->removeChildNodes()
                if $sel->can('removeChildNodes');
            # append one or more child nodes
            $each->($child_nodes, sub {
                my $node = shift or return;
                # deep clone child
                $sel->appendChild( $node->cloneNode(1) );
            });
        });
    }
    else {
        my $sel = $first->($xml);

        return $sel->toStringHTML
            if $sel->can('toStringHTML');
        return $sel->toString
            if $sel->can('toString');
        return;
    }

    return $X;
}

# text
#
# return text content
sub text
{
    my($X, $value) = @_;
    my $self = $X->($X);

    my $xml = $self->{_xml} or return $X;

    if (defined $value) {
        $each->($xml, sub {
            my $sel = shift or return;

            # text replaces everything else so remove child nodes
            # if they exist
            $sel->removeChildNodes() if $sel->can('removeChildNodes');

            # attempt different methods of adding text
            # XML::LibXML::Element
            if ($sel->can('appendText')) {
                $sel->appendText($value);
            }
            # XML::LibXML::Text
            elsif ($sel->can('setData')) {
                $sel->setData($value);
            }
            # XML::LibXML::Node
            elsif ($sel->can('appendChild')) {
                $sel->appendChild( $sel->createTextNode($value) );
            }
        });
    }
    else {
        my $sel = $first->($xml);
        return $sel && $sel->can('textContent')
            ? $sel->textContent
            : undef;
    }

    return $X;
}

# append
#
# add nodes after last child
sub append
{
    my($X) = shift;
    my $self = $X->($X);

    my $xml = $self->{_xml} or return $X;

    my $child_nodes = $arg_to_nodes->(@_)
        or return $X;

    $each->($xml, sub {
        my $sel = shift or return;
        # must be able to have children
        return unless $sel->can('appendChild');
        # append one or more child nodes
        $each->($child_nodes, sub {
            my $node = shift or return;
            # deep clone child
            $sel->appendChild( $node->cloneNode(1) );
        });
    });
}

# prepend
#
# add nodes before first child
sub prepend
{
    my($X) = shift;
    my $self = $X->($X);

    my $xml = $self->{_xml} or return $X;

    my $child_nodes = $arg_to_nodes->(@_)
        or return $X;

    my $first_child = shift @$child_nodes;

    $each->($xml, sub {
        my $sel = shift or return;

        if ($sel->can('firstChild')) {
            # insert first node before first child
            my $insert_after = $sel->insertBefore(
                $first_child->cloneNode(1),
                $sel->firstChild,
            ) or return;

            $each->($child_nodes, sub {
                my $node = shift or return;

                return unless $insert_after
                    and $insert_after->can('insertAfter');

                $insert_after = $sel->insertAfter(
                    $node->cloneNode(1),
                    $insert_after
                );
            });
        }
        elsif ($self->can('addChild')) {
            $sel->addChild( $first_child->cloneNode(1) );
            $each->($child_nodes, sub {
                my $node = shift or return;
            });
        }
        else {
            return;
        }
    });
}

# add/remove/toggle class using $mod_class
sub addClass    { $mod_class->('add', @_) }
sub removeClass { $mod_class->('remove', @_) }
sub toggleClass { $mod_class->('toggle', @_) }

1;

__END__

=head1 NAME

HTML::Xit - XML/HTML DOM Manipulation with CSS Selectors

=head1 SYNOPSIS

my $X = new HTML::Xit("http://mysite.com/mydoc.html");

$X->("a")->each( sub {
    my($X) = @_;

    print $X->attr("href");
    print $X->text;
    print $X->html;
} );

$X->(".a")->addClass("b c d")->removeClass("c e")->toggleClass("b a");

print $X->("<a>")->attr("href", "http://mysite.com")->text("My Site")->html;

=head1 DESCRIPTION

DOM manipulation in the style of jQuery using L<XML::LibXML> and L<HTML::Selector::XPath>.

=head1 METHODS

They all work sort of like jQuery ...

=over 4

=item each

=item attr

=item html

=item text

=item addClass

=item removeClass

=item toggleClass

=item append

=item prepend

=back

=head1 SEE ALSO

L<XML::LibXML>, L<HTML::Selector::XPath>

=head1 AUTHOR

Ersun Warncke, C<< <ersun.warncke at outlook.com> >>
http://ersun.warnckes.com

=head1 COPYRIGHT

Copyright (C) 2014 Ersun Warncke

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
