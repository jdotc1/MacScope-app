package main

//go:noinline
func ownedAdd(x int) int { return x + 17 }

//go:noinline
func ownedChoose(x int) int {
 if x < 0 { return ownedAdd(-x) }
 return ownedAdd(x)
}

func main() { println(ownedChoose(3)) }
