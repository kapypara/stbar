
namespace comm {

template<typename T>
class node {

    T* data = nullptr;

    node *previous = nullptr;
    node *next = nullptr;

// protected:
public:
    node* set_next(node &ptr){

        next = &ptr;
        return next;
    }

    node* set_pervious(node &ptr){


        previous = &ptr;
        return previous;
    }

    public:
    T set_data(T new_data){
        *data = new_data;
        return *data;
    }

    node* get_pervious(){
        return previous;
    }

    node* get_next(){
        return next;
    }

public:
    node() { data = new T; }
    ~node() { delete data; }

    node(T d) { data = new T(d); }

    node(T d, node* p) :previous(p) { data = new T(d); }

    node(T d, node* p, node* n) :previous(p), next(n) { data = new T(d); }

    operator T(){
        return *data;
    }

    T operator =(T rhs){
        return set_data(rhs);
    }

    bool operator ==(T rhs){
        return *this->data == rhs;
    }

};

}
