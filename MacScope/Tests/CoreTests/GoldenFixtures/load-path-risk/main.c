extern int weak_stub(void);
extern int found_stub(void);
int main(void) { return weak_stub() + found_stub(); }
