# visp-julia
Implementation of the data encoding method in the Julia language. StaticArray package is required.

Var soup_bit depends on lambda and, therefore, vector_x, vector_y.
In addition, get_next_bit depends on the result of update! (..., soup_bit), i.e. also - from soup_bit. 
From the lambda depend all the variables. Lambda is changing the next cycle.

The constructor Encoder() serves as an initializer, it reads the first 4 characters and sets the values:
- lambda; 
- vector_x; 
- vector_y.
