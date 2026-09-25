module Demo

# Include at least one dependency to ensure our `.ji` rewrite code tests this code path
using Random

greet(who::AbstractString) = "Hello, $who!"

end
