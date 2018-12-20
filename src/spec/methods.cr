module Spec::Methods
  # Defines an example group that describes a unit to be tested.
  # Inside *&block* examples are defined by `#it` or `#pending`.
  #
  # Several `describe` blocks can be nested.
  #
  # Example:
  # ```
  # describe "Int32" do
  #   describe "+" do
  #     it "adds" { (1 + 1).should eq 2 }
  #   end
  # end
  # ```
  def describe(description, file = __FILE__, line = __LINE__, &block)
    Spec::RootContext.describe(description.to_s, file, line, &block)
  end

  # Defines an example group that establishes a specific context,
  # like *empty array* versus *array with elements*.
  # Inside *&block* examples are defined by `#it` or `#pending`.
  #
  # It is functionally equivalent to `#describe`.
  def context(description, file = __FILE__, line = __LINE__, &block)
    describe(description.to_s, file, line, &block)
  end

  # Defines a concrete test case.
  #
  # The test is performed by the block supplied to *&block*.
  #
  # Example:
  # ```
  # it "adds" { (1 + 1).should eq 2 }
  # ```
  #
  # It is usually used inside a `#describe` or `#context` section.
  def it(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
    return unless Spec.matches?(description, file, line, end_line)

    Spec.formatters.each(&.before_example(description))

    start = Time.monotonic
    begin
      Spec.run_before_each_hooks
      with Scope yield
      Spec::RootContext.report(:success, description, file, line, Time.monotonic - start)
    rescue ex : Spec::AssertionFailed
      Spec::RootContext.report(:fail, description, file, line, Time.monotonic - start, ex)
      Spec.abort! if Spec.fail_fast?
    rescue ex
      Spec::RootContext.report(:error, description, file, line, Time.monotonic - start, ex)
      Spec.abort! if Spec.fail_fast?
    ensure
      Spec.run_after_each_hooks
    end
  end

  # Defines a pending test case.
  #
  # *&block* is never evaluated.
  # It can be used to describe behaviour that is not yet implemented.
  #
  # Example:
  # ```
  # pending "check cat" { cat.alive? }
  # ```
  #
  # It is usually used inside a `#describe` or `#context` section.
  def pending(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
    return unless Spec.matches?(description, file, line, end_line)

    # Run block on compile-time to detect nesting `it` and `pending`.
    typeof(with Scope yield)

    Spec.formatters.each(&.before_example(description))

    Spec::RootContext.report(:pending, description, file, line)
  end

  # Defines a yet-to-be-implemented pending test case
  def pending(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__)
    pending(description, file, line, end_line) { }
  end

  # DEPRECATED: Use `#it`
  def assert(file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
    {{ raise "'assert' was removed: use 'it' instead".id }}
  end

  # Fails an example.
  #
  # This method can be used to manually fail an example defined in an `#it` block.
  def fail(msg, file = __FILE__, line = __LINE__)
    raise Spec::AssertionFailed.new(msg, file, line)
  end

  # :nodoc:
  module Scope
    macro it(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
      {{ raise("cannot nest 'it' of spec") }}
    end

    macro pending(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
      {{ raise("cannot nest 'pending' of spec") }}
    end
  end
end

include Spec::Methods
