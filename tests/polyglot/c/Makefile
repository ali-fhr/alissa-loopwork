CFLAGS ?= -Wall -Wextra -Werror -O2

test_add: test_add.o add.o
	$(CC) $(CFLAGS) -o $@ $^

.PHONY: test
test: test_add
	./test_add
